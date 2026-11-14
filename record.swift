// Recording the whole screen: video, the Mac's sound and the microphone, into one MP4.
//
// Why it is built this way (macOS 27.2.1, measured 2026-11-14):
// - Reference: macOS's own recording (screencapture -v, the same as ScreenCaptureKit's SCRecordingOutput on
//   27) is H.264 Main, native pixels (3456 x 2234 here), variable frame rate up to the display's 120 Hz,
//   bt709, one AAC stereo 48 kHz track with the Mac's sound and the microphone mixed, 5-10 Mbit/s.
// - SCRecordingOutput itself needs macOS 15 and mixes the microphone into one track only from 27
//   (mixesAudioWithMicrophone). Players and Telegram play only the first audio track, so the mix is done
//   here: SCStream frames and sound (macOS 13+) and the microphone through AVCaptureSession (every
//   version) go into one AVAssetWriter. One path from macOS 13 to 27, and the bit rate is ours to set.
// - H.264, not HEVC: what macOS itself writes, and every phone, browser and messenger plays it. High
//   profile at about twice macOS's bit rate: same frames, fewer blocks in fast scrolling of small text.
// - Frames come only when the screen changes (ScreenCaptureKit's idle frames are skipped), so a still
//   screen costs almost nothing and the file has a variable frame rate, like macOS's own.
// - All three sources run on the host clock, so their timestamps place them on one time line.

import AVFoundation
import ScreenCaptureKit

/// Sums sound from several sources by their timestamps into one 48 kHz stereo stream.
/// A source's buffers follow each other without gaps or overlaps; a timestamp more than 50 ms off the
/// expected place (a dropout) moves the source there. What lies more than half a second behind the
/// newest sound is final and goes to the encoder; a buffer arriving later than that loses its late part.
final class Mixer {
    static let rate = 48000.0
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Mixer.rate, channels: 2, interleaved: false)!
    let start: CMTime
    private var left: [Float] = [], right: [Float] = []
    private var base: Int64 = 0              // time line position of left[0]
    private var next: [Int: Int64] = [:]     // per source: where its next buffer is expected
    private var converters: [Int: AVAudioConverter] = [:]
    private let hold = Int64(Mixer.rate / 2)

    init(start: CMTime) { self.start = start }

    /// Converts any PCM sample buffer to 48 kHz stereo float. Mono goes to both channels.
    func pcm(_ sample: CMSampleBuffer, source: Int) -> AVAudioPCMBuffer? {
        guard let desc = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        let inFormat = AVAudioFormat(cmAudioFormatDescription: desc)
        guard frames > 0, let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else { return nil }
        input.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList) == noErr else { return nil }
        if inFormat == format { return input }
        if asbd.mChannelsPerFrame == 1, asbd.mSampleRate == Mixer.rate, inFormat.commonFormat == .pcmFormatFloat32,
           let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames), let mono = input.floatChannelData?[0] {
            out.frameLength = frames
            for c in 0..<2 { out.floatChannelData![c].update(from: mono, count: Int(frames)) }
            return out
        }
        if converters[source]?.inputFormat != inFormat {
            converters[source] = AVAudioConverter(from: inFormat, to: format)
            if asbd.mChannelsPerFrame == 1 { converters[source]?.channelMap = [0, 0] }
        }
        guard let converter = converters[source] else { return nil }
        let capacity = AVAudioFrameCount(Double(frames) * Mixer.rate / asbd.mSampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var given = false
        _ = converter.convert(to: out, error: nil) { _, status in
            if given { status.pointee = .noDataNow; return nil }
            given = true; status.pointee = .haveData; return input
        }
        return out
    }

    func add(_ sample: CMSampleBuffer, source: Int) {
        guard let buffer = pcm(sample, source: source), let data = buffer.floatChannelData else { return }
        let n = Int64(buffer.frameLength)
        var at = Int64((CMSampleBufferGetPresentationTimeStamp(sample) - start).seconds * Mixer.rate)
        if let expected = next[source], abs(at - expected) < Int64(Mixer.rate / 20) { at = expected }
        next[source] = at + n
        let end = at + n
        if end > base + Int64(left.count) {
            let grow = Int(end - base) - left.count
            left.append(contentsOf: repeatElement(0, count: grow)); right.append(contentsOf: repeatElement(0, count: grow))
        }
        let from = max(at, base)
        guard from < end else { return }
        let skip = Int(from - at), into = Int(from - base)
        for i in 0..<Int(end - from) {
            left[into + i] += data[0][skip + i]
            right[into + i] += data[1][skip + i]
        }
    }

    /// Final sound as interleaved float sample buffers, clipped to full scale. `all` at the end.
    func take(all: Bool = false) -> CMSampleBuffer? {
        let newest = next.values.max() ?? base
        let upTo = all ? base + Int64(left.count) : min(newest - hold, base + Int64(left.count))
        let count = Int(upTo - base)
        guard count > 0 else { return nil }
        var interleaved = [Float](repeating: 0, count: count * 2)
        for i in 0..<count {
            interleaved[2 * i] = max(-1, min(1, left[i]))
            interleaved[2 * i + 1] = max(-1, min(1, right[i]))
        }
        let pts = start + CMTime(value: base, timescale: CMTimeScale(Mixer.rate))
        left.removeFirst(count); right.removeFirst(count)
        base = upTo
        return Mixer.sampleBuffer(interleaved, frames: count, at: pts)
    }

    static func sampleBuffer(_ samples: [Float], frames: Int, at pts: CMTime) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var desc: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                             magicCookie: nil, extensions: nil, formatDescriptionOut: &desc) == noErr, let desc else { return nil }
        let bytes = samples.count * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return nil }
        _ = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var out: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: desc,
                                                              sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &out)
        return out
    }
}

/// Facts about one recording, for tests and errors.
struct RecordingStats {
    var framesIn = 0, framesWritten = 0, systemBuffers = 0, micBuffers = 0
}

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let file: URL
    let queue = DispatchQueue(label: "recorder")   // every sample is handled here, in order
    private var stream: SCStream?
    private var mic: AVCaptureSession?
    private let writer: AVAssetWriter
    private var video: AVAssetWriterInput!
    private let audio: AVAssetWriterInput
    private var mixer: Mixer?
    private var pending: [CMSampleBuffer] = []
    private var stopping = false
    private(set) var stats = RecordingStats()
    var failure: Error?
    /// Called on the main queue when the stream stops by itself (the person stopped it from macOS's menu, a display went away).
    var stoppedBySystem: (() -> Void)?
    /// Set on the main queue just before stoppedBySystem: a stop that came while start() was still finishing is seen by the
    /// caller after start() returns, so the microphone does not go on alone (security pass 2026-11-14).
    var streamEnded = false

    init(file: URL) throws {
        self.file = file
        writer = try AVAssetWriter(outputURL: file, fileType: .mp4)
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Mixer.rate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000])
        audio.expectsMediaDataInRealTime = true
        super.init()
    }

    /// Starts recording a whole display; `microphone` nil records the Mac's sound only.
    func start(display id: CGDirectDisplayID, microphone: AVCaptureDevice?) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else {
            throw NSError(domain: "Pixlift", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display to record"])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        // The display's backing pixels in its current mode (3456 x 2234 here): what a screenshot of it has.
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let width = mode?.pixelWidth ?? display.width * 2, height = mode?.pixelHeight ?? display.height * 2
        let hz = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }?.maximumFramesPerSecond ?? 60

        let c = SCStreamConfiguration()
        c.width = width; c.height = height
        c.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(hz, 30)))
        c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange   // what the encoder takes, no conversion
        c.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        c.colorSpaceName = CGColorSpace.sRGB                              // bt709 primaries, as macOS's own recording
        c.showsCursor = true
        c.queueDepth = 8
        c.capturesAudio = true
        c.sampleRate = Int(Mixer.rate); c.channelCount = 2
        c.excludesCurrentProcessAudio = true

        // About 2x macOS's own (5-10 Mbit/s at 3456 x 2234), scaled by the number of pixels.
        let bitRate = max(4_000_000, Int(Double(width * height) * 2.6))
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitRate,
                                              AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                                              AVVideoExpectedSourceFrameRateKey: hz,
                                              AVVideoMaxKeyFrameIntervalDurationKey: 2]])
        video.expectsMediaDataInRealTime = true
        writer.add(video); writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "Pixlift", code: 2) }

        if let microphone {
            let session = AVCaptureSession()
            let input = try AVCaptureDeviceInput(device: microphone)
            let output = AVCaptureAudioDataOutput()
            output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Mixer.rate, AVLinearPCMBitDepthKey: 32,
                                    AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: true]
            output.setSampleBufferDelegate(self, queue: queue)
            if session.canAddInput(input) { session.addInput(input) }
            if session.canAddOutput(output) { session.addOutput(output) }
            mic = session
        }
        let s = SCStream(filter: filter, configuration: c, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        stream = s
        try await s.startCapture()
        mic?.startRunning()
    }

    // MARK: samples (on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopping, sample.isValid else { return }
        switch type {
        case .screen: frame(sample)
        case .audio: sound(sample, source: 0)
        default: break
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !stopping else { return }
        sound(sample, source: 1)
    }

    private func frame(_ sample: CMSampleBuffer) {
        guard let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              CMSampleBufferGetImageBuffer(sample) != nil else { return }
        stats.framesIn += 1
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if mixer == nil {
            writer.startSession(atSourceTime: pts)
            mixer = Mixer(start: pts)
        }
        if video.isReadyForMoreMediaData, video.append(sample) { stats.framesWritten += 1 }
    }

    private func sound(_ sample: CMSampleBuffer, source: Int) {
        guard let mixer else { return }   // sound starts with the first frame
        if source == 0 { stats.systemBuffers += 1 } else { stats.micBuffers += 1 }
        mixer.add(sample, source: source)
        if let out = mixer.take() { pending.append(out) }
        drain()
    }

    private func drain() {
        while let first = pending.first, audio.isReadyForMoreMediaData {
            audio.append(first)
            pending.removeFirst()
        }
    }

    // MARK: stop

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.streamEnded = true; self.stoppedBySystem?() }
    }

    /// Stops and finishes the file; it is complete when this returns.
    func stop() async throws {
        let end = CMClockGetTime(CMClockGetHostTimeClock())
        try? await stream?.stopCapture()
        mic?.stopRunning()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            queue.async {
                self.stopping = true
                guard let mixer = self.mixer else {
                    self.writer.cancelWriting()
                    c.resume(throwing: NSError(domain: "Pixlift", code: 3, userInfo: [NSLocalizedDescriptionKey: "No frame was recorded"]))
                    return
                }
                if let rest = mixer.take(all: true) { self.pending.append(rest) }
                // The encoder takes the last half second in a few milliseconds; two seconds is a stall, and the file is finished without it.
                for _ in 0..<1000 where !self.pending.isEmpty {
                    self.drain()
                    if !self.pending.isEmpty { usleep(2000) }
                }
                self.writer.endSession(atSourceTime: end)
                self.video.markAsFinished(); self.audio.markAsFinished()
                self.writer.finishWriting {
                    if self.writer.status == .completed { c.resume() } else { c.resume(throwing: self.writer.error ?? NSError(domain: "Pixlift", code: 4)) }
                }
            }
        }
    }
}
