// Pixlift: screenshots, screen recording, text and colour from the screen, one key each.
// Every capture lands on the Desktop and on the clipboard at once. Apple parts only: screencapture and
// ScreenCaptureKit, AVFoundation, Vision, NSColorSampler, Carbon hot keys; Sparkle for updates. No logs; the only
// network call is Sparkle's daily update check (updates.swift), which asks before installing anything.
//
// Test without touching the real clipboard (quit the app first, a hot key has one owner):
//   Pixlift.app/Contents/MacOS/Pixlift --pasteboard test
// OCR on files, prints instead of copying:
//   Pixlift.app/Contents/MacOS/Pixlift --file a.png b.png

import AppKit

startInBackgroundIfAtLogin()

let args = CommandLine.arguments
if args.count > 1 && args[1] == "--file" {
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
let pasteboard = args.count > 2 && args[1] == "--pasteboard" ? NSPasteboard(name: .init(args[2])) : .general

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = App(pasteboard: pasteboard)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
