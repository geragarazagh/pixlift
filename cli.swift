// Command line interface for Pixlift: OCR images, take headless screenshots, sample a screen pixel colour, and inspect status.
// Run as pixlift-cli (symlink to Pixlift.app/Contents/MacOS/Pixlift) or as Pixlift with subcommands:
//
//   pixlift-cli ocr FILE...                       extracts text (or QR code) from image files to stdout
//   pixlift-cli screenshot [-o FILE] [--display N] captures a full-screen PNG (default display 1)
//   pixlift-cli color X Y                         prints the sRGB #RRGGBB hex of the screen pixel at point (X, Y)
//   pixlift-cli status [--json]                   prints version, running state, destinations and permission status
//   pixlift-cli --file FILE...                    backwards-compatible alias for `ocr`
//   pixlift-cli --version | --help
//
// Every CLI command checks answersForItself() so another app cannot hijack Pixlift's TCC permissions via LaunchServices.

import AppKit
import AVFoundation

private let pixliftCliName = "pixlift-cli"

private let pixAppBundle: Bundle = {
    // executableURL, not argv[0]: run by name from PATH (the Homebrew symlink) argv[0] is the bare name, and the bundle
    // three levels above it is the current folder's, not the app's (measured 2026-11-23: version 0, settings unread).
    let real = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    let appURL = real.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return Bundle(url: appURL) ?? .main
}()

// Run from inside the bundle the process is the app itself: a suite named after its own id is refused (nil, and a
// console line «will not work» on every run), and .standard is that domain already. Through a symlink Bundle.main has
// no id, so the suite is what reaches the app's settings.
private var pixDefaults: UserDefaults {
    guard let id = pixAppBundle.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return .standard }
    return UserDefaults(suiteName: id) ?? .standard
}

private func pixFail(_ s: String) -> Never {
    FileHandle.standardError.write(Data((s + "\n").utf8))
    exit(1)
}

private func pixJSON(_ obj: Any) -> Never {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
          let text = String(data: data, encoding: .utf8) else { pixFail("Could not encode JSON.") }
    print(text)
    exit(0)
}

private func pixRunning() -> Bool {
    guard let id = pixAppBundle.bundleIdentifier else { return false }
    return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { $0.processIdentifier != getpid() }
}

private func runOCRFiles(_ paths: [String]) -> Never {
    guard !paths.isEmpty else { pixFail("No file given.") }
    let sem = DispatchSemaphore(value: 0)
    var failed = false
    Task.detached {
        for (i, path) in paths.enumerated() {
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                FileHandle.standardError.write(Data("unreadable: \(path)\n".utf8))
                failed = true
                continue
            }
            if paths.count > 1 { print((i > 0 ? "\n" : "") + "==> \(path) <==") }
            do { print(try await textFor(img)) } catch {
                FileHandle.standardError.write(Data("error (\(path)): \(error)\n".utf8))
                failed = true
            }
        }
        sem.signal()
    }
    sem.wait()
    exit(failed ? 1 : 0)
}

private func runScreenshot(_ args: [String], usage: String) -> Never {
    var outPath: String? = nil, display = 1
    var i = 0
    while i < args.count {
        switch args[i] {
        case "-o", "--output":
            guard i + 1 < args.count else { pixFail(usage) }
            outPath = args[i + 1]; i += 2
        case "--display", "-D":
            guard i + 1 < args.count, let d = Int(args[i + 1]), d >= 1 else { pixFail(usage) }
            display = d; i += 2
        default: pixFail(usage)
        }
    }
    guard CGPreflightScreenCaptureAccess() else {
        pixFail("No Screen Recording permission for the terminal running \(pixliftCliName).")
    }
    let dest: URL
    if let outPath {
        dest = URL(fileURLWithPath: outPath)
        if FileManager.default.fileExists(atPath: dest.path) { pixFail("File already exists: \(dest.path)") }
    } else {
        let d = Destinations(pixDefaults).get(.shot)
        let folder = (d.place == .folder ? d.folder.map { URL(fileURLWithPath: $0) } : nil) ?? desktop
        dest = freeName(in: folder, for: Date(), ext: "png")
    }
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pixlift-cli-\(UUID().uuidString).png")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-D", String(display), temp.path]
    do { try p.run(); p.waitUntilExit() } catch { pixFail("screencapture failed: \(error)") }
    guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: temp.path) else {
        try? FileManager.default.removeItem(at: temp)
        pixFail("Screenshot failed (check display number and Screen Recording permission).")
    }
    do {
        try FileManager.default.moveItem(at: temp, to: dest)
    } catch {
        try? FileManager.default.removeItem(at: temp)
        pixFail("Could not save screenshot to \(dest.path): \(error.localizedDescription)")
    }
    print(dest.path)
    exit(0)
}

@MainActor private func runColor(_ args: [String], usage: String) -> Never {
    guard args.count == 2, let x = Double(args[0]), let y = Double(args[1]) else { pixFail(usage) }
    guard CGPreflightScreenCaptureAccess() else {
        pixFail("No Screen Recording permission for the terminal running \(pixliftCliName).")
    }
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pixlift-color-\(UUID().uuidString).png")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-R", "\(Int(x)),\(Int(y)),1,1", temp.path]
    do { try p.run(); p.waitUntilExit() } catch { pixFail("screencapture failed: \(error)") }
    // Read, then removed at once: every way out below is exit(), which skips a defer (a defer here left one PNG of the
    // screen in TMPDIR per call, 2026-11-23).
    let data = try? Data(contentsOf: temp)
    try? FileManager.default.removeItem(at: temp)
    guard p.terminationStatus == 0,
          let data,
          let rep = NSBitmapImageRep(data: data),
          let color = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2),
          let hex = App.hex(color) else {
        pixFail("Could not read pixel at (\(Int(x)), \(Int(y))).")
    }
    print(hex)
    exit(0)
}

@MainActor private func runStatus(_ args: [String], usage: String) -> Never {
    let json = args == ["--json"]
    guard args.isEmpty || json else { pixFail(usage) }
    let version = pixAppBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    let running = pixRunning()
    let d = Destinations(pixDefaults)
    let shot = d.get(.shot), video = d.get(.video)
    let screenAccess = CGPreflightScreenCaptureAccess()
    let micStatus = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    func destDict(_ x: Destination) -> [String: Any] {
        var r: [String: Any] = ["saveTo": x.place.rawValue, "clipboard": x.clipboard]
        if let f = x.folder { r["folder"] = f }
        return r
    }
    if json {
        pixJSON([
            "version": version,
            "running": running,
            "screenAccess": screenAccess,
            "microphoneAccess": micStatus,
            "screenshots": destDict(shot),
            "recordings": destDict(video),
        ])
    }
    print("version: \(version)")
    print("running: \(running ? "yes" : "no")")
    print("screenshots: saveTo=\(shot.place.rawValue) clipboard=\(shot.clipboard ? "yes" : "no")\(shot.folder.map { " folder=\($0)" } ?? "")")
    print("recordings: saveTo=\(video.place.rawValue) clipboard=\(video.clipboard ? "yes" : "no")\(video.folder.map { " folder=\($0)" } ?? "")")
    exit(0)
}

@MainActor func runPixliftCLI(_ rawArgs: [String]) -> Bool {
    let exe = pixAppBundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? "Pixlift"
    let named = URL(fileURLWithPath: rawArgs[0]).lastPathComponent != exe
    let rest = Array(rawArgs.dropFirst())
    let usage = """
    Usage: \(pixliftCliName) ocr FILE...                          extracts text (or QR code) from image files
           \(pixliftCliName) screenshot [-o FILE] [--display N]   saves a full-screen PNG and prints its path
           \(pixliftCliName) color X Y                            prints sRGB #RRGGBB of screen pixel at (X, Y)
           \(pixliftCliName) status [--json]                      prints version, running state and destinations
           \(pixliftCliName) --version | --help
    """

    let guiFlags: Set<String> = ["--login", "--background", "--pasteboard"]
    guard let cmd = rest.first else {
        if named { print(usage); exit(0) }
        return false
    }

    switch cmd {
    case "--help", "-h":
        print(usage); exit(0)
    case "--version", "-V":
        let v = pixAppBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let n = pixAppBundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Pixlift"
        print("\(n) \(v)"); exit(0)
    case "--file", "ocr", "screenshot", "color", "status":
        break
    default:
        if named || (cmd.hasPrefix("--") && !guiFlags.contains(cmd)) { pixFail(usage) }
        return false
    }

    if answersForItself() {
        pixFail("\(pixliftCliName) works only from a terminal or script.")
    }

    let tail = Array(rest.dropFirst())
    switch cmd {
    case "--file", "ocr": runOCRFiles(tail)
    case "screenshot": runScreenshot(tail, usage: usage)
    case "color": runColor(tail, usage: usage)
    case "status": runStatus(tail, usage: usage)
    default: pixFail(usage)
    }
}
