// Tests that need no click: run by ./test (compiles the app's sources with this file instead of main.swift).
// Never touches the general clipboard: every pasteboard here is a private named one.
import AppKit
import AVFoundation
import Carbon.HIToolbox

let args = CommandLine.arguments
nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ what: String) { print(ok ? "PASS" : "FAIL", what); if !ok { failures += 1 } }

switch args[1] {
case "names":
    let dir = URL(fileURLWithPath: args[2])
    var parts = DateComponents(); parts.year = 2026; parts.month = 11; parts.day = 14; parts.hour = 5; parts.minute = 47; parts.second = 12
    let date = Calendar.current.date(from: parts)!
    let a = freeName(in: dir, for: date, ext: "png")
    check(a.lastPathComponent == "2026-11-14 05-47-12.png", "name \(a.lastPathComponent)")
    FileManager.default.createFile(atPath: a.path, contents: Data())
    let b = freeName(in: dir, for: date, ext: "png")
    check(b.lastPathComponent == "2026-11-14 05-47-12 (2).png", "clash \(b.lastPathComponent)")
    FileManager.default.createFile(atPath: b.path, contents: Data())
    let c = freeName(in: dir, for: date, ext: "png")
    check(c.lastPathComponent == "2026-11-14 05-47-12 (3).png", "clash \(c.lastPathComponent)")
    let v = freeName(in: dir, for: date, ext: "mp4")
    check(v.lastPathComponent == "2026-11-14 05-47-12.mp4", "video beside png \(v.lastPathComponent)")
    // Another calendar or digits must not leak in.
    let old = NSTimeZone.default
    NSTimeZone.default = TimeZone(identifier: "Europe/Kyiv")!
    check(!nameFormat.string(from: Date()).contains(where: { !"0123456789- ".contains($0) }), "only digits, dashes, space")
    NSTimeZone.default = old

case "clipboard":
    // args: file.png
    let file = URL(fileURLWithPath: args[2])
    let pb = NSPasteboard(name: .init("pixlift-test-\(getpid())"))
    let clip = Clipboard(pb)
    let t0 = Date()
    clip.put(file, picture: true)
    print(String(format: "write %.1f ms", Date().timeIntervalSince(t0) * 1000))
    check(pb.pasteboardItems?.count == 1, "one item (\(pb.pasteboardItems?.count ?? 0))")
    print("types:", pb.types?.map(\.rawValue) ?? [])
    let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    check(urls?.map(\.path) == [file.path], "file URL reads back as the file (\(urls?.map(\.path) ?? []))")
    check(pb.data(forType: .png) == (try? Data(contentsOf: file)), "PNG is the file's own bytes")
    let t1 = Date()
    let tiff = pb.data(forType: .tiff)
    print(String(format: "tiff on demand %.1f ms, %d bytes", Date().timeIntervalSince(t1) * 1000, tiff?.count ?? 0))
    let rep = tiff.flatMap { NSBitmapImageRep(data: $0) }
    let src = NSBitmapImageRep(data: try! Data(contentsOf: file))!
    check(rep?.pixelsWide == src.pixelsWide && rep?.pixelsHigh == src.pixelsHigh, "TIFF has the picture's pixels")
    check(rep?.colorSpace.localizedName == src.colorSpace.localizedName, "TIFF keeps the profile (\(rep?.colorSpace.localizedName ?? "-"))")
    let img = NSImage(pasteboard: pb)
    check(img != nil, "an image reader (NSImage) gets the picture")
    // The next capture replaces it.
    let movie = file.deletingLastPathComponent().appendingPathComponent("x.mp4")
    FileManager.default.createFile(atPath: movie.path, contents: Data())
    clip.put(movie, picture: false)
    let after = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
    check(after?.map(\.path) == [movie.path] && pb.data(forType: .png) == nil && pb.pasteboardItems?.count == 1, "a video replaces the picture: one file URL, no image")
    pb.releaseGlobally()

case "mix":
    // Two synthetic sources with jitter and a dropout: 440 Hz as the Mac's sound (stereo, 48 kHz, float),
    // 1000 Hz as the microphone (mono, 44.1 kHz, int16, through the converter). Output: args[2] (wav).
    let start = CMTime(value: 1_000_000, timescale: 1000)
    let mixer = Mixer(start: start)
    var out: [Float] = []
    func collect(_ b: CMSampleBuffer?) {
        guard let b, let block = CMSampleBufferGetDataBuffer(b) else { return }
        var len = 0; var ptr: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
        ptr!.withMemoryRebound(to: Float.self, capacity: len / 4) { out.append(contentsOf: UnsafeBufferPointer(start: $0, count: len / 4)) }
    }
    func buffer(freq: Double, rate: Double, channels: Int, int16: Bool, at: Double, frames: Int, phase: inout Double) -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: int16 ? (kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked) : (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked),
            mBytesPerPacket: UInt32((int16 ? 2 : 4) * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32((int16 ? 2 : 4) * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: int16 ? 16 : 32, mReserved: 0)
        var desc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &desc)
        var bytes = Data()
        for _ in 0..<frames {
            let v = sin(phase) * 0.4; phase += 2 * .pi * freq / rate
            for _ in 0..<channels {
                if int16 { var s = Int16(v * 32767); bytes.append(Data(bytes: &s, count: 2)) } else { var f = Float(v); bytes.append(Data(bytes: &f, count: 4)) }
            }
        }
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &block)
        bytes.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes.count) }
        var s: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: desc!, sampleCount: frames,
            presentationTimeStamp: start + CMTime(seconds: at, preferredTimescale: 1_000_000_000), packetDescriptions: nil, sampleBufferOut: &s)
        return s!
    }
    // 3 s: system 1024-frame buffers with ±2 ms jitter; mic 441-frame buffers, a 300 ms dropout at 1.5 s.
    var ps = 0.0, pm = 0.0, ts = 0.0, tm = 0.0
    var rng = SystemRandomNumberGenerator()
    while ts < 3 || tm < 3 {
        if ts <= tm {
            mixer.add(buffer(freq: 440, rate: 48000, channels: 2, int16: false, at: ts + Double.random(in: -0.002...0.002, using: &rng), frames: 1024, phase: &ps), source: 0)
            ts += 1024 / 48000
        } else {
            if !(1.5...1.8).contains(tm) { mixer.add(buffer(freq: 1000, rate: 44100, channels: 1, int16: true, at: tm, frames: 441, phase: &pm), source: 1) } else { pm += 2 * .pi * 1000 * 441 / 44100 }
            tm += 441 / 44100
        }
        collect(mixer.take())
    }
    collect(mixer.take(all: true))
    let frames = out.count / 2
    print("mixed frames:", frames, String(format: "(%.3f s)", Double(frames) / 48000))
    check(abs(Double(frames) / 48000 - 3.0) < 0.05, "length matches the sources")
    // Goertzel power of each tone, per channel, in the first second and inside the dropout.
    func power(_ f: Double, ch: Int, from: Double, to: Double) -> Double {
        let a = Int(from * 48000), b = Int(to * 48000)
        let k = 2 * cos(2 * .pi * f / 48000); var s1 = 0.0, s2 = 0.0
        for i in a..<b { let s0 = Double(out[2 * i + ch]) + k * s1 - s2; s2 = s1; s1 = s0 }
        return (s1 * s1 + s2 * s2 - k * s1 * s2) / Double((b - a) * (b - a))
    }
    for ch in 0..<2 {
        let p440 = power(440, ch: ch, from: 0.2, to: 1.2), p1000 = power(1000, ch: ch, from: 0.2, to: 1.2)
        print(String(format: "ch%d 440Hz %.4f 1000Hz %.4f", ch, p440, p1000))
        check(p440 > 0.03 && p1000 > 0.03, "both sources in channel \(ch)")
    }
    check(power(1000, ch: 0, from: 1.55, to: 1.75) < 0.001 && power(440, ch: 0, from: 1.55, to: 1.75) > 0.03, "the dropout is silence in the mic part only")
    check(out.allSatisfy { abs($0) <= 1 }, "nothing over full scale")
    // Clicks: a jittered source must stay continuous. Largest sample-to-sample jump vs. a clean 440+1000 sum.
    var jump: Float = 0
    for i in 1..<Int(1.4 * 48000) where i > 4800 { jump = max(jump, abs(out[2 * i] - out[2 * (i - 1)])) }
    let w: Double = 2 * Double.pi / 48000
    let bound = Float(0.4 * w * 1440 * 1.1)
    print(String(format: "largest step %.4f (smooth bound %.4f)", jump, bound))
    check(jump <= bound, "no clicks from the jitter")
    // Write a wav to listen to or probe.
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true)!
    let file = try! AVAudioFile(forWriting: URL(fileURLWithPath: args[2]), settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
    let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
    pcm.frameLength = AVAudioFrameCount(frames)
    out.withUnsafeBufferPointer { pcm.floatChannelData![0].update(from: $0.baseAddress!, count: out.count) }
    try! file.write(from: pcm)

case "record":
    // args: seconds out.mp4 [nomic]: the app's own recorder on the display under the pointer.
    let seconds = Double(args[2])!
    let url = URL(fileURLWithPath: args[3])
    let useMic = args.count < 5
    Task {
        do {
            let r = try Recorder(file: url)
            let t0 = Date()
            try await r.start(display: displayUnderPointer().id, microphone: useMic ? AVCaptureDevice.default(for: .audio) : nil)
            print(String(format: "started in %.2f s", Date().timeIntervalSince(t0)))
            try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            let t1 = Date()
            try await r.stop()
            print(String(format: "stop -> file complete in %.3f s", Date().timeIntervalSince(t1)))
            print("frames in \(r.stats.framesIn), written \(r.stats.framesWritten), system sound buffers \(r.stats.systemBuffers), mic buffers \(r.stats.micBuffers)")
        } catch { print("FAIL record:", error); exit(1) }
        exit(0)
    }
    RunLoop.main.run()

case "keys":
    // Registers the six default keys as the app does, prints each row's state, then presses every key
    // but ⌥⌘6 (OCR.app may hold it) as synthetic events and prints which actions ran.
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let w = AppWindow(name: "Pixlift", rows: Action.allCases.map { a in Row(id: a.id, label: a.label, defaultShortcut: a.defaultShortcut) { print("ran", a) } }, showAtLaunch: false)
        for i in w.rows.indices { print(Action.allCases[i], w.describe(i)) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            for a in Action.allCases where a != .text {
                let src = CGEventSource(stateID: .hidSystemState)
                for down in [true, false] {
                    let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(a.defaultShortcut.key), keyDown: down)!
                    e.flags = [.maskCommand, .maskAlternate]
                    e.post(tap: .cghidEventTap)
                }
                usleep(150_000)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { exit(0) }
        app.run()
    }

case "render":
    // args: out.png light|dark. Draws the window off screen (run from a copy inside the app bundle so the
    // language files and the icon are found; -AppleLanguages picks the language).
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let w = AppWindow(name: "Pixlift", rows: Action.allCases.map { a in Row(id: a.id, label: a.label, defaultShortcut: a.defaultShortcut) { } }, showAtLaunch: false)
        w.panel.appearance = NSAppearance(named: args[3] == "dark" ? .darkAqua : .aqua)
        if args.count > 4 { w.startRecording(0) }
        w.refresh()
        let v = w.panel.contentView!
        v.layoutSubtreeIfNeeded()
        let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
        v.cacheDisplay(in: v.bounds, to: rep)
        // The window's own background under the views, as the window draws it.
        let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        w.panel.appearance!.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill(); NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill()
        }
        rep.draw(in: NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
        NSGraphicsContext.restoreGraphicsState()
        try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
        // Labels that don't fit their frame, in this language.
        for (i, l) in w.labels.enumerated() where l.attributedStringValue.size().width + 4 > l.frame.width { print("CLIPPED label", i, l.stringValue) }
        for (i, l) in w.notes.enumerated() where l.attributedStringValue.size().width > l.frame.width { print("CLIPPED note", i, l.stringValue) }
        for b in w.buttons where b.attributedTitle.size().width + 24 > b.frame.width { print("CLIPPED button", b.title) }
        print("rendered", Int(v.bounds.width), "x", Int(v.bounds.height))
        exit(0)
    }

default:
    print("unknown test"); exit(2)
}
exit(failures == 0 ? 0 : 1)
