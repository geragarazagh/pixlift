// What each key does, the permissions, and where every capture goes (the settings: destinations.swift).
// The app's name lives in one place: the build script (Info.plist); the code reads it from the bundle.

import AppKit
import AVFoundation
import Carbon.HIToolbox

let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Pixlift"

enum Action: CaseIterable {
    case area, window, screen, record, text, colour

    var label: String {
        switch self {
        case .area: return L("Capture Selected Portion")   // macOS's own words (screencaptureui), ru and uk too
        case .window: return L("Capture Selected Window")
        case .screen: return L("Capture Entire Screen")
        case .record: return L("Record Entire Screen")
        case .text: return L("Copy Text")
        case .colour: return L("Copy Color")
        }
    }

    /// ⌥⌘ with the digits his mouse already sends: 7 8 9 screenshots, 0 records, 6 text (OCR's key), 5 colour.
    var defaultShortcut: Shortcut {
        let keys: [Action: Int] = [.area: kVK_ANSI_7, .window: kVK_ANSI_8, .screen: kVK_ANSI_9, .record: kVK_ANSI_0, .text: kVK_ANSI_6, .colour: kVK_ANSI_5]
        return Shortcut(key: keys[self]!, mods: cmdKey | optionKey)
    }

    var id: String { "\(self)" }
}

@MainActor final class App: NSObject, NSApplicationDelegate {
    let clipboard: Clipboard
    let destinations = Destinations()
    let clipboardFiles: ClipboardFiles
    var sweeper: Timer?
    let engine = Engine()
    let sampler = NSColorSampler()
    var samplerSession = 0
    var interactive = false        // a crosshair or window picker of screencapture is up
    var recorder: Recorder?
    var recordingStarted = Date()
    var starting = false
    var window: AppWindow?

    init(pasteboard: NSPasteboard) {
        clipboard = Clipboard(pasteboard)
        clipboardFiles = ClipboardFiles(pasteboard: pasteboard)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        _ = Updates.shared   // starts the daily check (updates.swift)
        destinations.migrate(macOS: Destinations.macOSPrefs())   // before the window marks the app as launched
        clipboardFiles.sweep()
        sweeper = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.clipboardFiles.sweep() }
        }
        window = AppWindow(name: appName, rows: Action.allCases.map { a in
            Row(id: a.id, label: a.label, defaultShortcut: a.defaultShortcut) { [weak self] in self?.run(a) }
        }, extra: DestinationsView(width: AppWindow.W, margin: AppWindow.M, controlW: AppWindow.controlW, settings: destinations))
        // Vision compiles its model per app on first use (~30 s): done at launch, as OCR.app does, so the
        // first ⌥⌘6 is quick. It reads only its own test card, no screen.
        Task {
            await engine.warmUp()
            if let f = await engine.failure { report("\(appName): \(L("OCR self-test"))", f) }
        }
    }

    func applicationShouldHandleReopen(_ a: NSApplication, hasVisibleWindows: Bool) -> Bool {
        window?.show()
        return false
    }

    // Quit while recording: the file is finished and delivered first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recorder != nil else { return .terminateNow }
        Task { await stopRecording(); NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func run(_ a: Action) {
        switch a {
        case .area: still(.area)
        case .window: still(.window)
        case .screen: still(.screen)
        case .record: toggleRecording()
        case .text: text()
        case .colour: colour()
        }
    }

    // MARK: permissions

    /// Screen Recording, asked the first time a key needs it: macOS's own question once, then, for whoever
    /// declined or missed it, this app's alert at every press with the way to the switch.
    func screenAllowed() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        let d = UserDefaults.standard
        if !d.bool(forKey: "askedScreen") {
            d.set(true, forKey: "askedScreen")
            CGRequestScreenCaptureAccess()
            return false
        }
        if alert(String(format: L("%@ needs screen access"), appName), L("Privacy & Security > Screen & System Audio Recording"),
                 [L("Open System Settings"), L("Cancel")]) == 0 {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        return false
    }

    /// The microphone for a recording: macOS's question the first time; nil records the Mac's sound only.
    func microphone() async -> AVCaptureDevice?? {
        guard let device = AVCaptureDevice.default(for: .audio) else { return .some(nil) }   // a Mac without one
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return device
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio) ? device : .some(nil)
        default:
            switch alert(String(format: L("%@ needs microphone access"), appName), L("Privacy & Security > Microphone"),
                         [L("Open System Settings"), L("Record Without Microphone"), L("Cancel")]) {
            case 0: NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!); return nil
            case 1: return .some(nil)
            default: return nil
            }
        }
    }

    var alertOpen = false
    /// Index of the button pressed. A press of any key while an alert is open does nothing.
    func alert(_ title: String, _ info: String, _ buttons: [String]) -> Int {
        alertOpen = true
        defer { alertOpen = false }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        for b in buttons { a.addButton(withTitle: b) }
        a.window.level = .floating
        return a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    // MARK: stills

    func still(_ kind: Still) {
        guard !alertOpen, !(interactive && kind != .screen), screenAllowed() else { return }
        if kind != .screen { interactive = true }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pixlift-\(UUID().uuidString).png")
        Task {
            let taken = await screencapture(kind.arguments, to: temp)
            if kind != .screen { interactive = false }
            guard taken else { return }   // Esc
            do {
                try place(temp, .shot, date: Date(), ext: "png")
                if recorder == nil { AudioServicesPlaySystemSound(shutter) }
            } catch {
                try? FileManager.default.removeItem(at: temp)
                report("\(appName): \(L("The screenshot was not saved"))", "\(error)")
            }
        }
    }

    /// Saves and copies a finished capture as its kind's settings say. A screenshot that is only copied goes as the
    /// picture and its file is deleted; a recording that is only copied stays a file in the clipboard folder
    /// (destinations.swift). A picked folder that is gone gets the Desktop instead, and the person is told.
    func place(_ temp: URL, _ kind: Kind, date: Date, ext: String) throws {
        let copy = destinations.get(kind).clipboard
        if let (folder, missing) = destinations.folder(kind) {
            let file = try deliver(temp, to: folder, date: date, ext: ext)
            if copy { clipboard.put(file, picture: kind == .shot) }
            if let missing {
                report("\(appName): " + String(format: L("The folder “%@” can’t be found."), FileManager.default.displayName(atPath: missing)),
                       "\(missing)\n\(L("Saved to the Desktop:")) \(file.path)")
            }
        } else if kind == .shot {
            let data = try Data(contentsOf: temp)
            clipboard.put(picture: data)
            try? FileManager.default.removeItem(at: temp)
        } else {
            let file = try clipboardFiles.keep(temp, date: date, ext: ext)
            clipboard.put(file, picture: false)
            clipboardFiles.placed(file)
        }
        clipboardFiles.sweep()
    }

    // MARK: recording

    func toggleRecording() {
        guard !alertOpen, !starting else { return }
        if recorder != nil { Task { await stopRecording() }; return }
        guard screenAllowed() else { return }
        starting = true
        Task {
            defer { starting = false }
            guard let mic = await microphone() else { return }   // the person chose Cancel or Settings
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pixlift-\(UUID().uuidString).mp4")
            do {
                let r = try Recorder(file: temp)
                r.stoppedBySystem = { [weak self] in Task { await self?.stopRecording() } }
                recordingStarted = Date()
                try await r.start(display: displayUnderPointer().id, microphone: mic)
                recorder = r
                // macOS stopped the stream before start() returned: its stoppedBySystem found no recorder yet.
                if r.streamEnded { await stopRecording() }
            } catch {
                try? FileManager.default.removeItem(at: temp)
                report("\(appName): \(L("The recording did not start"))", "\(error)")
            }
        }
    }

    func stopRecording() async {
        guard let r = recorder else { return }
        recorder = nil
        let started = recordingStarted   // a new recording may start during the await below and set its own
        do {
            try await r.stop()
            try place(r.file, .video, date: started, ext: "mp4")
        } catch {
            try? FileManager.default.removeItem(at: r.file)
            report("\(appName): \(L("The recording was not saved"))", "\(error)")
        }
    }

    // MARK: text and colour

    func text() {
        guard !alertOpen, !interactive, screenAllowed() else { return }
        interactive = true
        Task {
            let result = await engine.run()
            interactive = false
            switch result {
            case .success(let text) where text.isEmpty: break
            case .success(let text):
                clipboard.pasteboard.clearContents()
                clipboard.pasteboard.setString(text, forType: .string)
            case .failure(let e):
                report("\(appName): \(L("OCR failed"))", "\(e)")
            }
        }
    }

    /// Apple's colour loupe, no permission. A click copies "#RRGGBB" in sRGB, as #HEX does (its notes: hex/main.swift).
    func colour() {
        samplerSession += 1
        let mine = samplerSession
        sampler.show { [weak self] color in
            DispatchQueue.main.async {
                guard let self, mine == self.samplerSession, let color, let hex = App.hex(color) else { return }
                self.clipboard.pasteboard.clearContents()
                self.clipboard.pasteboard.setString(hex, forType: .string)
            }
        }
    }

    static func hex(_ color: NSColor) -> String? {
        guard let c = color.usingColorSpace(.extendedSRGB) else { return nil }
        let v = [c.redComponent, c.greenComponent, c.blueComponent].map { max(0, min(255, Int(($0 * 255).rounded()))) }
        return String(format: "#%02X%02X%02X", v[0], v[1], v[2])
    }
}
