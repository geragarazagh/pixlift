// Pixlift: screenshots, screen recording, text and colour from the screen, one key each.
// Every capture lands on the Desktop and on the clipboard at once. Apple parts only: screencapture and
// ScreenCaptureKit, AVFoundation, Vision, NSColorSampler, Carbon hot keys; Sparkle for updates. No logs; the only
// network call is Sparkle's daily update check (updates.swift), which asks before installing anything.
//
// Test without touching the real clipboard (quit the app first, a hot key has one owner; from a terminal only):
//   Pixlift.app/Contents/MacOS/Pixlift --pasteboard test
// OCR on files, prints instead of copying (from a terminal only):
//   Pixlift.app/Contents/MacOS/Pixlift --file a.png b.png

import AppKit

startInBackgroundIfAtLogin()

// True when macOS counts this process as its own responsible program, so its permissions are the app's own: launched as
// an app (`open -n -a Pixlift --args …`), as a launchd job, or with responsibility disclaimed. Run from Terminal, the
// responsible program is Terminal and its permissions apply. The lookup is libsystem's
// responsibility_get_pid_responsible_for_pid (in no header, present since macOS 10.14); without it, a parent of launchd
// counts as the same. STT's cli.swift, security pass 2026-11-10.
func answersForItself() -> Bool {
    typealias Lookup = @convention(c) (pid_t) -> pid_t
    let me = getpid()
    if let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") {   // RTLD_DEFAULT
        let r = unsafeBitCast(f, to: Lookup.self)(me)
        if r > 0 { return r == me }
    }
    return getppid() == 1
}

let args = CommandLine.arguments
// The command-line modes act only for a caller that answers for itself (security pass 2026-11-14): started by another
// program as an app, --file would read pictures with Pixlift's own folder permissions (the Desktop's, which saving
// screenshots there needs) and hand their text to that program, and --pasteboard would send every capture to a
// pasteboard of its choosing.
let commandLine = !answersForItself()
if args.count > 1 && args[1] == "--file" {
    guard commandLine else { FileHandle.standardError.write(Data("--file works only from a terminal\n".utf8)); exit(1) }
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        for path in args.dropFirst(2) {
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("unreadable: \(path)"); continue }
            do { print(try await textFor(img)) } catch { print("error: \(error)") }
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}
let pasteboard = commandLine && args.count > 2 && args[1] == "--pasteboard" ? NSPasteboard(name: .init(args[2])) : .general

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = App(pasteboard: pasteboard)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
