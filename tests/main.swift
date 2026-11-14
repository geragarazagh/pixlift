// Tests that need no click: run by ./test (compiles the app's sources with this file instead of main.swift).
// Never touches the general clipboard: every pasteboard here is a private named one.
import AppKit
import AVFoundation
import Carbon.HIToolbox

let args = CommandLine.arguments
nonisolated(unsafe) var failures = 0
// One defaults suite for every settings test, emptied before each use and deleted at the end: a suite per case left a
// plist per case and run in ~/Library/Preferences (removePersistentDomain empties a domain, its file stays).
let suite = "pixlift-tests-settings"
func freshDefaults() -> UserDefaults {
    let d = UserDefaults(suiteName: suite)!
    d.removePersistentDomain(forName: suite)
    return d
}
func dropDefaults() {
    UserDefaults().removePersistentDomain(forName: suite)
    CFPreferencesAppSynchronize(suite as CFString)
    let file = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Preferences/\(suite).plist")
    try? FileManager.default.removeItem(at: file)
}
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
    // A screenshot that is not saved: the picture alone, no file URL.
    let bytes = try! Data(contentsOf: file)
    clip.put(picture: bytes)
    let none = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    check(pb.pasteboardItems?.count == 1 && none.isEmpty && pb.data(forType: .png) == bytes, "picture only: one item, PNG, no file")
    check(NSBitmapImageRep(data: pb.data(forType: .tiff) ?? Data())?.pixelsWide == src.pixelsWide, "picture only: TIFF on demand")
    pb.releaseGlobally()

case "destinations":
    // args: a scratch folder. The settings logic of 0.2 on a private defaults suite, never the app's own.
    let dir = URL(fileURLWithPath: args[2])
    func fresh(_ name: String) -> UserDefaults { freshDefaults() }
    // The legacy folder sits in the home folder, so that `~` in macOS's value is really expanded (removed at the end).
    let shots = dir.appendingPathComponent("Shots"), legacy = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/pixlift-test-\(getpid())")
    defer { try? FileManager.default.removeItem(at: legacy) }
    for f in [shots, legacy] { try! FileManager.default.createDirectory(at: f, withIntermediateDirectories: true) }

    // A new person, macOS never told anything: the Desktop, clipboard off, both kinds (macOS 27.2's own default, measured).
    var d = fresh("new"); var s = Destinations(d)
    s.migrate(macOS: [:])
    check(s.get(.shot) == Destination(place: .desktop, clipboard: false) && s.get(.video) == Destination(place: .desktop, clipboard: false),
          "new person: Desktop, clipboard off (\(s.get(.shot)), \(s.get(.video)))")
    check(s.folder(.shot)?.url == desktop && s.folder(.shot)?.missing == nil, "new person: saved to \(s.folder(.shot)?.url.path ?? "-")")
    check(d.string(forKey: "shot.saveTo") == "desktop" && d.object(forKey: "shot.clipboard") as? Bool == false, "the first launch writes the settings out")

    // Someone who ran 0.1: the Desktop and the clipboard, both, as 0.1 always did.
    d = fresh("upgrade"); d.set(true, forKey: "launched"); s = Destinations(d)
    s.migrate(macOS: ["location": shots.path, "target": "clipboard"])
    check(s.get(.shot) == Destination(place: .desktop, clipboard: true) && s.get(.video) == Destination(place: .desktop, clipboard: true),
          "0.1 user keeps Desktop + clipboard, whatever macOS says (\(s.get(.shot)), \(s.get(.video)))")
    // Migration runs once: a later choice stays.
    s.set(.shot, Destination(place: .notSaved, clipboard: true))
    s.migrate(macOS: [:])
    check(s.get(.shot).place == .notSaved, "migration does not run twice")

    // macOS 13-15 (and 27 before its Screenshot tool was opened): one `location` for both kinds, `~` expanded.
    d = fresh("legacy"); s = Destinations(d)
    let tilde = legacy.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    check(tilde.hasPrefix("~/"), "legacy test value \(tilde)")
    s.migrate(macOS: ["location": tilde + "/"])
    check(s.get(.shot) == Destination(place: .folder, folder: legacy.path, clipboard: false) && s.get(.video).folder == legacy.path,
          "legacy location for both (\(s.get(.shot).folder ?? "-"))")

    // macOS 27: a place per kind; no location-screenrecording beside its target means the Desktop, even with a stale `location`.
    d = fresh("split"); s = Destinations(d)
    s.migrate(macOS: ["target-screenshot": "file", "target-screenrecording": "file", "location-screenshot": shots.path, "location": legacy.path])
    check(s.get(.shot).folder == shots.path && s.get(.shot).place == .folder, "27: screenshots to location-screenshot")
    check(s.get(.video).place == .desktop, "27: recordings without location-screenrecording go to the Desktop")

    // Screenshots set to Clipboard in macOS: clipboard on, not saved. Recordings have no such target.
    d = fresh("clip"); s = Destinations(d)
    s.migrate(macOS: ["target-screenshot": "clipboard", "target-screenrecording": "file"])
    check(s.get(.shot) == Destination(place: .notSaved, clipboard: true) && s.get(.video) == Destination(place: .desktop, clipboard: false),
          "macOS Clipboard: shots copied only, recordings saved")

    // A location that is not a folder, or is the Desktop itself: the Desktop.
    for loc in [dir.appendingPathComponent("gone").path, desktop.path + "/", "/etc/hosts"] {
        let x = Destinations(fresh("bad")); x.migrate(macOS: ["location": loc])
        check(x.get(.shot) == Destination(place: .desktop, clipboard: false), "location \(loc): the Desktop")
    }

    // Both off is refused, from either side.
    d = fresh("both"); s = Destinations(d); s.migrate(macOS: [:])
    check(!s.set(.shot, Destination(place: .notSaved, clipboard: false)) && s.get(.shot).place == .desktop, "None refused while the clipboard is off")
    check(s.set(.shot, Destination(place: .notSaved, clipboard: true)), "None allowed with the clipboard on")
    check(!s.set(.shot, Destination(place: .notSaved, clipboard: false)) && s.get(.shot).clipboard, "clipboard off refused while not saved")
    check(!s.set(.video, Destination(place: .folder, folder: nil, clipboard: true)), "a folder without a path refused")
    // A pair edited by hand into both off reads as copied.
    d.set("none", forKey: "video.saveTo"); d.set(false, forKey: "video.clipboard")
    check(s.get(.video) == Destination(place: .notSaved, clipboard: true), "hand-edited both off reads as clipboard on")

    // A picked folder that went away: the Desktop, and its path is reported.
    let tmpFolder = dir.appendingPathComponent("Unplugged")
    try! FileManager.default.createDirectory(at: tmpFolder, withIntermediateDirectories: true)
    s.set(.video, Destination(place: .folder, folder: tmpFolder.path, clipboard: false))
    check(s.folder(.video)?.url.path == tmpFolder.path && s.folder(.video)?.missing == nil, "picked folder used")
    try! FileManager.default.removeItem(at: tmpFolder)
    check(s.folder(.video)?.url == desktop && s.folder(.video)?.missing == tmpFolder.path, "missing folder: Desktop, reported")
    // Desktop chosen again: the picked folder is remembered for the menu.
    s.set(.video, Destination(place: .desktop, folder: shots.path, clipboard: false))
    check(s.get(.video).folder == shots.path && s.folder(.video)?.url == desktop, "Desktop chosen, picked folder remembered")
    dropDefaults()

case "sweep":
    // args: a scratch folder. Recordings kept only for the clipboard: deleted once off the clipboard and an hour old.
    let dir = URL(fileURLWithPath: args[2]).appendingPathComponent("Clipboard")
    let d = freshDefaults()
    let pb = NSPasteboard(name: .init("pixlift-test-sweep-\(getpid())"))
    let files = ClipboardFiles(folder: dir, defaults: d, pasteboard: pb)
    let clip = Clipboard(pb)
    func temp() -> URL { let u = URL(fileURLWithPath: args[2]).appendingPathComponent(UUID().uuidString + ".mp4"); FileManager.default.createFile(atPath: u.path, contents: Data([1])); return u }
    let date = Date()
    let a = try! files.keep(temp(), date: date, ext: "mp4")
    clip.put(a, picture: false); files.placed(a)
    check(a.deletingLastPathComponent().path == dir.path && a.lastPathComponent == nameFormat.string(from: date) + ".mp4", "kept under its own name in the clipboard folder (\(a.lastPathComponent))")
    files.sweep(now: date.addingTimeInterval(7200))
    check(FileManager.default.fileExists(atPath: a.path), "on the clipboard: kept, however old")
    let b = try! files.keep(temp(), date: date, ext: "mp4")
    clip.put(b, picture: false); files.placed(b)
    check(b.lastPathComponent.hasSuffix(" (2).mp4"), "a second one beside it: \(b.lastPathComponent)")
    files.sweep(now: date.addingTimeInterval(60))
    check(FileManager.default.fileExists(atPath: a.path), "off the clipboard but young: kept (a paste may still be reading it)")
    files.sweep(now: date.addingTimeInterval(7200))
    check(!FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path), "off the clipboard and old: deleted; the one on it stays")
    pb.clearContents(); pb.setString("something else", forType: .string)
    files.sweep(now: date.addingTimeInterval(7200))
    check(!FileManager.default.fileExists(atPath: b.path) && !FileManager.default.fileExists(atPath: dir.path), "clipboard moved on: deleted, the empty folder too")
    pb.releaseGlobally()
    dropDefaults()

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

case "qr":
    // Copy Text: visible text wins over a barcode in the same area; a barcode alone gives its payload. The QR is drawn
    // at 2 % contrast (250 on 255), which Vision still decodes (security pass 2026-11-14).
    let payload = "https://example.com/not-what-was-selected"
    let gen = CIFilter(name: "CIQRCodeGenerator")!
    gen.setValue(Data(payload.utf8), forKey: "inputMessage")
    let qrImage = gen.outputImage!.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
    let ctx = CIContext()
    func draw(text: String?, qrShade: CGFloat) -> CGImage {
        let size = CGSize(width: 1400, height: 520)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
        if let text {
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
                .draw(in: NSRect(x: 40, y: 40, width: 900, height: 440))
        }
        // The QR's dark modules in a near-white grey, its light ones in white.
        let tinted = qrImage.applyingFilter("CIFalseColor", parameters: [
            "inputColor0": CIColor(red: qrShade, green: qrShade, blue: qrShade), "inputColor1": CIColor.white])
        let cg = ctx.createCGImage(tinted, from: tinted.extent)!
        NSGraphicsContext.current!.cgContext.draw(cg, in: CGRect(x: 980, y: 60, width: tinted.extent.width, height: tinted.extent.height))
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        let mixed = (try? await textFor(draw(text: "Run this in Terminal:\nbrew install geragarazagh/tap/pixlift", qrShade: 250 / 255))) ?? ""
        check(mixed.contains("brew install") && !mixed.contains("example.com"), "text beside a faint QR: the text (\(mixed.replacingOccurrences(of: "\n", with: " / ")))")
        let faintOnly = (try? await textFor(draw(text: nil, qrShade: 250 / 255))) ?? ""
        check(faintOnly == payload, "a faint QR alone: its payload (\(faintOnly))")
        let only = (try? await textFor(draw(text: nil, qrShade: 0))) ?? ""
        check(only == payload, "a QR alone: its payload (\(only))")
        sem.signal()
    }
    sem.wait()

case "render":
    // args: out.png light|dark. Draws the window off screen (run from a copy inside the app bundle so the
    // language files and the icon are found; -AppleLanguages picks the language).
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // The settings as args[4] says: "default" (a new person), "upgrade" (0.1: both on), "mixed" (a picked folder for
        // screenshots, recordings copied only: None picked, the switch greyed).
        let d = freshDefaults()   // in "show" mode it stays until the next run or `defaults delete pixlift-tests-settings`
        let s = Destinations(d)
        let mode = args.count > 4 ? args[4] : "default"
        if mode == "upgrade" { d.set(true, forKey: "launched") }
        s.migrate(macOS: [:])
        if mode == "mixed" {
            s.set(.shot, Destination(place: .folder, folder: NSHomeDirectory() + "/Pictures", clipboard: false))
            s.set(.video, Destination(place: .notSaved, clipboard: true))
        }
        let extra = DestinationsView(width: AppWindow.W, margin: AppWindow.M, controlW: AppWindow.controlW, settings: s)
        let w = AppWindow(name: "Pixlift", rows: Action.allCases.map { a in Row(id: a.id, label: a.label, defaultShortcut: a.defaultShortcut) { } }, extra: extra, showAtLaunch: false)
        w.panel.appearance = NSAppearance(named: args[3] == "dark" ? .darkAqua : .aqua)
        if args.contains("recording") { w.startRecording(0) }
        w.refresh()
        // "show": the real window on screen in the chosen theme, for a screenshot of it (run in a session of its own).
        if args.contains("show") {
            w.panel.center()
            w.panel.orderFrontRegardless()
            w.panel.makeKey()
            NSApp.activate(ignoringOtherApps: true)
            app.run()
        }
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
        for l in extra.labels where l.attributedStringValue.size().width + 4 > l.frame.width { print("CLIPPED label", l.stringValue) }
        // Every pop-up item, as the closed pop-up would show it once chosen (the picked folder may truncate, by design).
        for p in extra.popups.values {
            let chosen = p.selectedItem
            for item in p.itemArray where !item.isSeparatorItem && ![2, 3].contains(item.tag) {
                p.select(item)   // the cell's title rect is the one of the shown item
                let need = NSAttributedString(string: item.title, attributes: [.font: p.font as Any]).size().width
                let room = p.cell!.titleRect(forBounds: p.bounds).width
                if need > room { print("CLIPPED popup item", item.title, Int(need), ">", Int(room)) }
            }
            p.select(chosen)
        }
        for v in extra.subviews { for o in extra.subviews where o !== v && v.frame.intersects(o.frame) { print("OVERLAP", v, o) } }
        print("rendered", Int(v.bounds.width), "x", Int(v.bounds.height))
        dropDefaults()
        exit(0)
    }

default:
    print("unknown test"); exit(2)
}
exit(failures == 0 ? 0 : 1)
