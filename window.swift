// The app's whole interface: one small window of a fixed size. Opening the app shows it, closing it
// leaves the hot keys working in the background, with nothing in the Dock or the menu bar.
// The window.swift of #HEX and OCR, grown from one shortcut row to one per action; Check for Updates… 32 pt
// under the version as in theirs. 400 pt wide, not 340: macOS's own Russian «Снимок выбранной области»
// and the button's «Натисніть скорочення» don't both fit a 340 pt row (measured on the rendered window).
//
// - Hot keys are Carbon RegisterEventHotKey: no Accessibility permission. Stored as virtual key codes,
//   physical keys, so they work in every keyboard layout.
// - macOS does not report a key held by another app: RegisterEventHotKey answers noErr, and both apps
//   then act on one press (measured on 27.2.1 with two processes). The author's own single-function
//   apps (OCR, #HEX) are known: while one runs with the same key, that row stays off and names it.
//   Keys of other apps can't be seen. macOS acts on its own keys before an app hears them, so only
//   what reaches the app is checked.

import AppKit
import Carbon.HIToolbox
import ServiceManagement

struct Shortcut: Equatable {
    var key: Int    // virtual key code
    var mods: Int   // Carbon modifiers: cmdKey, optionKey, controlKey, shiftKey
}

struct Row {
    let id: String          // the name its key is stored under
    let label: String
    let defaultShortcut: Shortcut
    let action: () -> Void
    init(id: String = "", label: String, defaultShortcut: Shortcut, action: @escaping () -> Void) {
        self.id = id.isEmpty ? label : id; self.label = label; self.defaultShortcut = defaultShortcut; self.action = action
    }
}

/// The author's apps that each do one of this app's jobs, and the keys they use unless changed.
private let siblings: [(id: String, name: String, shortcut: Shortcut)] = [
    ("com.geragaraza.ocr", "OCR", Shortcut(key: kVK_ANSI_6, mods: cmdKey | optionKey)),
    ("com.geragaraza.hex", "#HEX", Shortcut(key: kVK_ANSI_0, mods: cmdKey | optionKey))]

/// The name of a running sibling app holding this key, if any.
private func heldBySibling(_ s: Shortcut) -> String? {
    for app in siblings where !NSRunningApplication.runningApplications(withBundleIdentifier: app.id).isEmpty {
        let key = CFPreferencesCopyAppValue("key" as CFString, app.id as CFString) as? Int
        let mods = CFPreferencesCopyAppValue("mods" as CFString, app.id as CFString) as? Int
        let theirs = key.map { Shortcut(key: $0, mods: mods ?? 0) } ?? app.shortcut
        if theirs == s { return app.name }
    }
    return nil
}

private let functionKeys: [Int: String] = [
    kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
    kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14",
    kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20"]

private let namedKeys: [Int: String] = [
    kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
    kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ForwardDelete: "⌦", kVK_Delete: "⌫", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Escape: "Esc"]

// The Latin character of a key, whatever layout is on: a shortcut reads ⌘K, not ⌘Л.
private func keyName(_ key: Int) -> String {
    if let name = functionKeys[key] ?? namedKeys[key] { return name }
    guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
          let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
    let data = unsafeBitCast(raw, to: CFData.self)
    let layout = unsafeBitCast(CFDataGetBytePtr(data), to: UnsafePointer<UCKeyboardLayout>.self)
    var dead: UInt32 = 0, count = 0
    var chars = [UniChar](repeating: 0, count: 4)
    UCKeyTranslate(layout, UInt16(key), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                   OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &count, &chars)
    return String(utf16CodeUnits: chars, count: count).uppercased()
}

func title(_ s: Shortcut) -> String {
    (s.mods & controlKey != 0 ? "⌃" : "") + (s.mods & optionKey != 0 ? "⌥" : "")
        + (s.mods & shiftKey != 0 ? "⇧" : "") + (s.mods & cmdKey != 0 ? "⌘" : "") + keyName(s.key)
}

// Keys macOS lists as its own. Most never reach the app; the ones that do are named as a conflict.
private func takenByMacOS(_ s: Shortcut) -> Bool {
    var list: Unmanaged<CFArray>?
    guard CopySymbolicHotKeys(&list) == noErr, let all = list?.takeRetainedValue() as? [[String: Any]] else { return false }
    let mask = cmdKey | optionKey | controlKey | shiftKey
    return all.contains {
        ($0[kHISymbolicHotKeyEnabled] as? Bool) == true && ($0[kHISymbolicHotKeyCode] as? Int) == s.key
            && (($0[kHISymbolicHotKeyModifiers] as? Int) ?? -1) & mask == s.mods
    }
}

// Open at Login is a launchd agent (Contents/Library/LaunchAgents in the bundle) that passes --login:
// an app started as a login item can't otherwise tell that from being opened by hand, and only the
// second should show the window. The agent's copy only starts the app through `open` and exits,
// because launchd kills what it started when the agent is unregistered, and that would take the
// running app down with the switch.
func startInBackgroundIfAtLogin() {
    guard CommandLine.arguments.contains("--login") else { return }
    let me = ProcessInfo.processInfo.processIdentifier
    if !NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "").contains(where: { $0.processIdentifier != me }) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", Bundle.main.bundlePath, "--args", "--background"]
        try? p.run()
        p.waitUntilExit()
    }
    exit(0)
}

// The English text is the key; ru and uk come from lang/, picked by macOS from the system language.
// Wording of macOS's own terms (Open at Login, Quit, Privacy & Security) is copied from its .loctable files.
func L(_ s: String) -> String { NSLocalizedString(s, comment: "") }

// Carbon's handler is a C function and can capture nothing.
private var onHotKey: ((UInt32) -> Void)?

func report(_ title: String, _ details: String) {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.messageText = title
    let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
    field.string = details; field.isEditable = false; field.isSelectable = true
    field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    let scroll = NSScrollView(frame: field.frame); scroll.documentView = field; scroll.hasVerticalScroller = true
    a.accessoryView = scroll
    a.addButton(withTitle: "OK")
    a.addButton(withTitle: L("Copy"))
    if a.runModal() == .alertSecondButtonReturn {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("\(title)\n\(details)", forType: .string)
    }
}

// The app's own icon, as Finder shows it now: on macOS 26+ the icon follows the theme (Assets.car), so it is fetched
// again whenever the window's appearance changes; NSApp.applicationIconImage keeps the one from launch.
final class AppIconView: NSImageView {
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refresh() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }
    // NSWorkspace hands the icon over at 32 x 32 pt and NSImageView only scales down, so it would show at half the
    // view's size: the image is given the view's size (the icon is multi-resolution, so it stays sharp).
    private func refresh() {
        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        icon.size = bounds.size
        image = icon
    }
}

@MainActor final class AppWindow: NSObject, NSWindowDelegate {
    let name: String
    let login: SMAppService
    let rows: [Row]
    var shortcuts: [Shortcut]
    var hotKeys: [EventHotKeyRef?]
    var holder: [String?]          // a sibling app holding the row's key
    var failed: [Bool]             // the row's key was refused
    var recordingRow: Int?         // the row whose key is being recorded
    let panel: NSPanel
    var buttons: [NSButton] = []
    var labels: [NSTextField] = []
    var notes: [NSTextField] = []  // a row's state, under its label
    let loginSwitch = NSSwitch()

    private static let W: CGFloat = 400, M: CGFloat = 20, rowH: CGFloat = 34, rowsY: CGFloat = 96

    init(name: String, rows: [Row], showAtLaunch: Bool = true) {
        self.name = name
        self.rows = rows
        let id = Bundle.main.bundleIdentifier ?? ""
        login = SMAppService.agent(plistName: "\(id).login.plist")
        let d = UserDefaults.standard
        shortcuts = rows.map { r in
            d.object(forKey: "\(r.id).key") == nil ? r.defaultShortcut : Shortcut(key: d.integer(forKey: "\(r.id).key"), mods: d.integer(forKey: "\(r.id).mods"))
        }
        hotKeys = Array(repeating: nil, count: rows.count)
        holder = Array(repeating: nil, count: rows.count)
        failed = Array(repeating: false, count: rows.count)
        let top = Self.rowsY + CGFloat(rows.count - 1) * Self.rowH + 28
        // Non-activating: it takes the keys even when macOS declines to bring a background app forward.
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.W, height: top + 172), styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()

        onHotKey = { [weak self] n in
            guard let self, n >= 1, Int(n) <= self.rows.count, self.recordingRow == nil else { return }
            self.rows[Int(n) - 1].action()
        }
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { onHotKey?(id.id) }
            return noErr
        }, 1, &specs, nil, nil)

        build()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            return self.keyDown(e)
        }
        // A sibling that quits frees its key, one that starts takes it.
        for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: n, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard siblings.contains(where: { $0.id == app?.bundleIdentifier }) else { return }
                MainActor.assumeIsolated { self?.registerAll(); self?.refresh() }
            }
        }

        registerAll()
        // Open at Login stays off until a person turns it on: an app adds nothing to their login items by itself.
        // The switch is in this window, which the first launch shows.
        let first = !d.bool(forKey: "launched")
        if first { d.set(true, forKey: "launched") }
        if showAtLaunch && (first || failed.contains(true) || !CommandLine.arguments.contains("--background")) { show() }
    }

    /// A row's state in words, for the window and for tests.
    func describe(_ i: Int) -> String {
        if let h = holder[i] { return String(format: L("Used by %@"), h) }
        if failed[i] { return L("This shortcut can’t be used") }
        return hotKeys[i] == nil ? L("None") : title(shortcuts[i])
    }

    // MARK: window

    func build() {
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        let v = panel.contentView!
        let W = Self.W, M = Self.M
        let top = Self.rowsY + CGFloat(rows.count - 1) * Self.rowH + 28

        func text(_ s: String, _ font: NSFont, _ color: NSColor, _ frame: NSRect, _ align: NSTextAlignment) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = font; l.textColor = color; l.alignment = align; l.frame = frame
            l.lineBreakMode = .byTruncatingTail
            v.addSubview(l)
            return l
        }

        let icon = AppIconView(frame: NSRect(x: (W - 64) / 2, y: top + 82, width: 64, height: 64))
        v.addSubview(icon)
        _ = text(name, .boldSystemFont(ofSize: 15), .labelColor, NSRect(x: M, y: top + 56, width: W - 2 * M, height: 20), .center)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        _ = text(version, .systemFont(ofSize: 11), .secondaryLabelColor, NSRect(x: M, y: top + 40, width: W - 2 * M, height: 14), .center)
        // Updates.shared is made on the first click, not here: the off-screen tests build this window without Sparkle running.
        let updates = NSButton(title: L("Check for Updates…"), target: self, action: #selector(checkForUpdates))
        updates.bezelStyle = .rounded
        updates.controlSize = .small
        updates.font = .systemFont(ofSize: 11)
        updates.refusesFirstResponder = true
        updates.sizeToFit()
        updates.frame.origin = NSPoint(x: (W - updates.frame.width) / 2, y: top + 8)
        v.addSubview(updates)

        let buttonW: CGFloat = 150, labelW = W - 2 * M - buttonW - 8
        for (i, row) in rows.enumerated() {
            let y = Self.rowsY + CGFloat(rows.count - 1 - i) * Self.rowH
            labels.append(text(row.label, .systemFont(ofSize: 13), .labelColor, NSRect(x: M, y: y + 5, width: labelW, height: 18), .left))
            notes.append(text("", .systemFont(ofSize: 10), .secondaryLabelColor, NSRect(x: M, y: y - 1, width: labelW, height: 13), .left))
            let b = NSButton(title: "", target: self, action: #selector(keyButtonClicked(_:)))
            b.frame = NSRect(x: W - M - buttonW, y: y, width: buttonW, height: 28)
            b.bezelStyle = .rounded
            b.setButtonType(.pushOnPushOff)
            b.tag = i
            b.refusesFirstResponder = true
            v.addSubview(b)
            buttons.append(b)
        }

        _ = text(L("Open at Login"), .systemFont(ofSize: 13), .labelColor, NSRect(x: M, y: 59, width: 236, height: 18), .left)
        loginSwitch.controlSize = .small
        loginSwitch.sizeToFit()
        loginSwitch.frame.origin = NSPoint(x: W - M - loginSwitch.frame.width + 5, y: 58)   // the switch draws 5 pt inside its frame
        loginSwitch.target = self; loginSwitch.action = #selector(loginChanged)
        loginSwitch.refusesFirstResponder = true
        v.addSubview(loginSwitch)

        // The repository's address comes from Info.plist (GitHubURL, written by ./build from the app's name).
        let github = Bundle.main.object(forInfoDictionaryKey: "GitHubURL") as? String ?? "https://github.com/geragarazagh"
        var x = M
        for (label, url) in [(L("Herman Harazha"), "https://geragaraza.com"), (L("GitHub"), github)] {
            let b = NSButton(title: label, target: self, action: #selector(openLink(_:)))
            b.isBordered = false
            b.attributedTitle = NSAttributedString(string: label, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.linkColor])
            b.toolTip = url
            b.refusesFirstResponder = true
            b.sizeToFit()
            b.frame.origin = NSPoint(x: x, y: 20)
            v.addSubview(b)
            x += b.frame.width + 12
        }
        // A background app with no menu has no other way to be stopped.
        let quit = NSButton(title: L("Quit"), target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.bezelStyle = .rounded
        quit.controlSize = .small
        quit.font = .systemFont(ofSize: 11)
        quit.refusesFirstResponder = true
        quit.sizeToFit()
        quit.frame.origin = NSPoint(x: W - M - quit.frame.width, y: 16)
        v.addSubview(quit)
    }

    func show() {
        refresh()
        if !panel.isVisible { panel.center() }
        panel.orderFrontRegardless()
        panel.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        Updates.shared.appOpened()
    }

    @objc func checkForUpdates() { Updates.shared.check() }

    func refresh() {
        for i in rows.indices { setNote(i, holder[i].map { String(format: L("Used by %@"), $0) } ?? (failed[i] ? L("This shortcut can’t be used") : "")) }
        for (i, b) in buttons.enumerated() {
            b.state = .off
            b.title = recordingRow == i ? L("Press a shortcut") : (hotKeys[i] == nil && holder[i] == nil ? L("None") : title(shortcuts[i]))
            b.state = recordingRow == i ? .on : .off
            // A key another app holds is shown, greyed: it works again when that app quits.
            if holder[i] != nil && recordingRow != i {
                b.attributedTitle = NSAttributedString(string: b.title, attributes: [.foregroundColor: NSColor.disabledControlTextColor, .font: b.font as Any])
            }
        }
        loginSwitch.state = login.status == .enabled ? .on : .off
    }

    /// A note under a row's label; the label moves up to make room for it.
    func setNote(_ i: Int, _ s: String) {
        guard i < notes.count else { return }
        notes[i].stringValue = s
        let y = Self.rowsY + CGFloat(rows.count - 1 - i) * Self.rowH
        labels[i].frame.origin.y = s.isEmpty ? y + 5 : y + 11
    }

    func windowDidBecomeKey(_ n: Notification) { loginSwitch.state = login.status == .enabled ? .on : .off }
    func windowDidResignKey(_ n: Notification) { cancelRecording() }
    func windowWillClose(_ n: Notification) { cancelRecording() }

    @objc func openLink(_ b: NSButton) {
        if let s = b.toolTip, let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }

    @objc func loginChanged() {
        do {
            if loginSwitch.state == .on {
                if login.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() } else { try login.register() }
            } else {
                try login.unregister()
            }
        } catch {
            report("\(name): \(L("Open at Login"))", "\(error)")
        }
        loginSwitch.state = login.status == .enabled ? .on : .off
    }

    // MARK: hot keys

    func register(_ i: Int) {
        unregister(i)
        holder[i] = heldBySibling(shortcuts[i])
        guard holder[i] == nil else { failed[i] = false; return }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4B45_5931), id: UInt32(i + 1))
        failed[i] = RegisterEventHotKey(UInt32(shortcuts[i].key), UInt32(shortcuts[i].mods), id, GetApplicationEventTarget(), 0, &ref) != noErr
        hotKeys[i] = failed[i] ? nil : ref
    }

    func unregister(_ i: Int) {
        if let k = hotKeys[i] { UnregisterEventHotKey(k) }
        hotKeys[i] = nil
    }

    func registerAll() { for i in rows.indices where i != recordingRow { register(i) } }

    // MARK: recording a key

    @objc func keyButtonClicked(_ b: NSButton) {
        let same = recordingRow == b.tag
        cancelRecording()
        if !same { startRecording(b.tag) }
    }

    // The row's key is unregistered first: a registered hot key never reaches the app as a key
    // press, so pressing the same key again could not be recorded.
    func startRecording(_ i: Int) {
        recordingRow = i
        unregister(i)
        refresh()
    }

    func cancelRecording() {
        guard let i = recordingRow else { return }
        recordingRow = nil
        register(i)
        refresh()
    }

    func keyDown(_ e: NSEvent) -> NSEvent? {
        guard e.window === panel else { return e }
        let f = e.modifierFlags
        var mods = 0
        if f.contains(.command) { mods |= cmdKey }
        if f.contains(.option) { mods |= optionKey }
        if f.contains(.control) { mods |= controlKey }
        if f.contains(.shift) { mods |= shiftKey }
        let key = Int(e.keyCode)

        guard let i = recordingRow else {
            if key == kVK_Escape && mods == 0 || key == kVK_ANSI_W && mods == cmdKey { panel.performClose(nil); return nil }
            if key == kVK_ANSI_Q && mods == cmdKey { NSApp.terminate(nil); return nil }
            return e
        }
        if key == kVK_Escape && mods == 0 { cancelRecording(); return nil }
        record(i, Shortcut(key: key, mods: mods))
        return nil
    }

    func record(_ i: Int, _ new: Shortcut) {
        // A plain letter or Shift + letter would stop typing that letter everywhere. F-keys type nothing.
        if new.mods & (cmdKey | optionKey | controlKey) == 0 && functionKeys[new.key] == nil {
            setNote(i, L("Needs ⌘, ⌥ or ⌃")); return
        }
        if shortcuts.indices.contains(where: { $0 != i && shortcuts[$0] == new }) { setNote(i, L("Already in use")); return }
        if takenByMacOS(new) { setNote(i, L("Conflicts with macOS")); return }
        let old = shortcuts[i]
        shortcuts[i] = new
        register(i)
        if failed[i] { shortcuts[i] = old; failed[i] = false; setNote(i, L("This shortcut can’t be used")); return }
        UserDefaults.standard.set(new.key, forKey: "\(rows[i].id).key")   // nosemgrep (a shortcut key code in the app's own defaults, not a secret)
        UserDefaults.standard.set(new.mods, forKey: "\(rows[i].id).mods")
        recordingRow = nil
        refresh()
    }
}
