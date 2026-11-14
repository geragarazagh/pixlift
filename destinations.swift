// Where a capture goes (0.2): screenshots and recordings each have two settings, in the words of macOS's own Screenshot
// tool (screencaptureui's Options menu): «Save to» the Desktop, a folder picked with «Other Location…», or «None», and
// «Clipboard» on or off. One of the two always stays on for each kind, or the capture would go nowhere: the window
// disables the control that would turn the second one off, and this file refuses that pair whoever asks.
//
// Defaults, measured 2026-11-14 on macOS 27.2 on a user that had never opened the Screenshot tool: its Options menu
// ticks Desktop for screenshots and for recordings, and a capture landed on the Desktop; no `location` key is written
// until a person picks another place. So a new person starts where macOS's own screenshots go, clipboard off:
// - The folder is taken from com.apple.screencapture once, at the first launch, so a person who sent macOS's screenshots
//   to a folder finds Pixlift's there too. macOS 27 keeps one place per kind (location-screenshot and
//   location-screenrecording, written together with target-screenshot and target-screenrecording; a missing location
//   there means the Desktop; 26.6 has neither key in screencapture or screencaptureui). macOS 13-26, and 27 before its
//   Screenshot tool was first opened, keep one `location` for both. A place that is not an existing folder means the
//   Desktop.
// - Screenshots set to Clipboard in macOS (target-screenshot or target = clipboard) start as clipboard on, not saved.
//   Recordings have no Clipboard target in macOS, so they always start saved.
// - After that the settings are Pixlift's own: a later change in macOS's tool does not move them.
// Upgrading from 0.1, which always saved to the Desktop and copied too, keeps exactly that (migrate()).
//
// The app is not sandboxed, so a folder is kept as a plain path: a security-scoped bookmark only matters inside the
// sandbox, and a path is what `defaults read` shows and `defaults write` can set.

import AppKit

enum Kind: String, CaseIterable { case shot, video }

enum Place: String { case desktop, folder, notSaved = "none" }   // "none": the stored value, as macOS's word

struct Destination: Equatable {
    var place: Place
    var folder: String? = nil   // the folder picked with Other Location…, remembered while the Desktop is chosen
    var clipboard: Bool
}

var desktop: URL { FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0] }

func isFolder(_ path: String) -> Bool {
    var dir: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
}

final class Destinations {
    let d: UserDefaults
    init(_ d: UserDefaults = .standard) { self.d = d }

    private func key(_ k: Kind, _ name: String) -> String { "\(k.rawValue).\(name)" }

    /// macOS's own screenshot settings of this user, read once at the first launch.
    static func macOSPrefs() -> [String: Any] {
        let domain = "com.apple.screencapture" as CFString
        guard let keys = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { return [:] }
        return CFPreferencesCopyMultiple(keys, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] ?? [:]
    }

    /// What macOS itself does with this kind of capture for this user (see the header).
    static func macOSDefault(_ k: Kind, _ prefs: [String: Any]) -> Destination {
        let name = k == .shot ? "screenshot" : "screenrecording"
        let split = prefs["target-\(name)"] != nil
        let target = (split ? prefs["target-\(name)"] : prefs["target"]) as? String
        if k == .shot && target == "clipboard" { return Destination(place: .notSaved, clipboard: true) }
        guard let raw = (split ? prefs["location-\(name)"] : prefs["location"]) as? String, !raw.isEmpty else {
            return Destination(place: .desktop, clipboard: false)
        }
        let path = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL.path
        if !isFolder(path) || path == desktop.standardizedFileURL.path { return Destination(place: .desktop, clipboard: false) }
        return Destination(place: .folder, folder: path, clipboard: false)
    }

    /// The first launch of 0.2 writes both kinds' settings once, so they never depend on a default again. Someone who ran
    /// 0.1 (it set `launched` on its first launch) keeps 0.1's behaviour: the Desktop and the clipboard, both. A new person
    /// gets macOS's own. Must run before the window sets `launched`.
    func migrate(macOS: @autoclosure () -> [String: Any]) {
        let upgrading = d.bool(forKey: "launched")
        for k in Kind.allCases where d.object(forKey: key(k, "saveTo")) == nil {
            write(k, upgrading ? Destination(place: .desktop, clipboard: true) : Self.macOSDefault(k, macOS()))
        }
    }

    func get(_ k: Kind) -> Destination {
        var place = Place(rawValue: d.string(forKey: key(k, "saveTo")) ?? "") ?? .desktop
        let folder = d.string(forKey: key(k, "folder"))
        if place == .folder && folder == nil { place = .desktop }
        var clipboard = d.bool(forKey: key(k, "clipboard"))
        if place == .notSaved && !clipboard { clipboard = true }   // a pair edited by hand: a capture is never lost
        return Destination(place: place, folder: folder, clipboard: clipboard)
    }

    /// False, and nothing changes, when the pair would neither save nor copy.
    @discardableResult func set(_ k: Kind, _ new: Destination) -> Bool {
        guard new.place != .notSaved || new.clipboard, new.place != .folder || new.folder != nil else { return false }
        write(k, new)
        return true
    }

    private func write(_ k: Kind, _ v: Destination) {
        d.set(v.place.rawValue, forKey: key(k, "saveTo"))
        if let f = v.folder { d.set(f, forKey: key(k, "folder")) } else { d.removeObject(forKey: key(k, "folder")) }
        d.set(v.clipboard, forKey: key(k, "clipboard"))
    }

    /// The folder a capture of this kind is saved to, nil when it is not saved. A picked folder that is gone (a disk
    /// unplugged, the folder deleted) gives the Desktop and its own path as `missing`, so the capture is kept and the
    /// person is told.
    func folder(_ k: Kind) -> (url: URL, missing: String?)? {
        let v = get(k)
        switch v.place {
        case .notSaved: return nil
        case .desktop: return (desktop, nil)
        case .folder:
            guard let f = v.folder, isFolder(f) else { return (desktop, v.folder) }
            return (URL(fileURLWithPath: f, isDirectory: true), nil)
        }
    }
}

// MARK: recordings that live only on the clipboard

// A recording set to Clipboard with «Save to: None» must still be a file: the clipboard carries a recording as its file
// URL, and the app it is pasted into reads that file, maybe later (a long upload, a clipboard manager's history). It
// lives in ~/Library/Caches/com.geragaraza.pixlift/Clipboard under the capture's own name, beside Vision's model, so
// Pixlift's files stay in one removable place and `brew uninstall --zap` takes them. Not $TMPDIR: macOS deletes what
// lies there unopened for three days, under a paste that may still come.
// Cleaning: a file goes once it is no longer on the clipboard (the clipboard's change count moved on since Pixlift put
// it there) and is more than an hour old. The hour covers a paste still being read when the clipboard moves on; the
// check runs at launch, after every capture and every hour. While it stays on the clipboard it stays on disk, quits and
// relaunches included (the count survives them; a restart empties the clipboard, and the count with it).

final class ClipboardFiles {
    static let grace: TimeInterval = 3600
    let folder: URL
    let d: UserDefaults
    let pasteboard: NSPasteboard

    init(folder: URL? = nil, defaults: UserDefaults = .standard, pasteboard: NSPasteboard) {
        self.folder = folder ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.geragaraza.pixlift").appendingPathComponent("Clipboard")
        d = defaults
        self.pasteboard = pasteboard
    }

    /// Moves a finished recording here under its own name; call `placed` once it is on the clipboard.
    func keep(_ temp: URL, date: Date, ext: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = freeName(in: folder, for: date, ext: ext)
        try FileManager.default.moveItem(at: temp, to: dest)
        return dest
    }

    func placed(_ file: URL) {
        d.set(file.lastPathComponent, forKey: "clipboardFile")   // a name in this folder: paths may come back through /private
        d.set(pasteboard.changeCount, forKey: "clipboardFile.count")
    }

    /// Deletes what is off the clipboard and older than the grace; the folder itself goes when empty.
    func sweep(now: Date = Date()) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let onClipboard = d.integer(forKey: "clipboardFile.count") == pasteboard.changeCount ? d.string(forKey: "clipboardFile") : nil
        for f in files where f.lastPathComponent != onClipboard {
            let made = (try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if now.timeIntervalSince(made) > Self.grace { try? fm.removeItem(at: f) }
        }
        if (try? fm.contentsOfDirectory(atPath: folder.path))?.isEmpty == true { try? fm.removeItem(at: folder) }
    }
}

// MARK: the window's part

/// Two sections, Screenshot and Screen Recording, each «Save to» [pop-up] and «Clipboard» [switch], in the columns of the
/// key rows above: labels from the left margin, the pop-up as wide as a key button, the switch where Open at Login's is.
@MainActor final class DestinationsView: NSView {
    static let headerH: CGFloat = 28, popupRowH: CGFloat = 32, switchRowH: CGFloat = 28
    static var height: CGFloat { CGFloat(Kind.allCases.count) * (headerH + popupRowH + switchRowH) }

    let settings: Destinations
    var popups: [Kind: NSPopUpButton] = [:]
    var switches: [Kind: NSSwitch] = [:]
    var labels: [NSTextField] = []

    override var isFlipped: Bool { true }

    init(width W: CGFloat, margin M: CGFloat, controlW: CGFloat, settings: Destinations) {
        self.settings = settings
        super.init(frame: NSRect(x: 0, y: 0, width: W, height: Self.height))
        var y: CGFloat = 0
        func text(_ s: String, _ font: NSFont, _ color: NSColor, _ frame: NSRect) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = font; l.textColor = color; l.frame = frame
            l.lineBreakMode = .byTruncatingTail
            addSubview(l)
            labels.append(l)
            return l
        }
        for k in Kind.allCases {
            // Section titles as macOS's own menus set them (the Options menu's «Save to»): small, bold, secondary.
            let section = k == .shot ? L("Screenshot") : L("Screen Recording")
            _ = text(section, .systemFont(ofSize: 11, weight: .semibold), .secondaryLabelColor,
                     NSRect(x: M, y: y + 12, width: W - 2 * M, height: 14))
            y += Self.headerH
            _ = text(L("Save to"), .systemFont(ofSize: 13), .labelColor, NSRect(x: M, y: y + 7, width: W - 2 * M - controlW - 12, height: 18))
            let p = NSPopUpButton(frame: .zero, pullsDown: false)
            p.autoenablesItems = false
            p.target = self; p.action = #selector(placeChosen(_:))
            p.refusesFirstResponder = true
            p.sizeToFit()
            p.frame = NSRect(x: W - M - controlW, y: y + (Self.popupRowH - p.frame.height) / 2, width: controlW, height: p.frame.height)
            p.tag = k == .shot ? 0 : 1
            p.setAccessibilityLabel("\(section), \(L("Save to"))")   // VoiceOver: which of the two pop-ups
            addSubview(p)
            popups[k] = p
            y += Self.popupRowH
            let s = NSSwitch()
            s.controlSize = .small
            s.sizeToFit()
            _ = text(L("Clipboard"), .systemFont(ofSize: 13), .labelColor, NSRect(x: M, y: y + 4, width: W - 2 * M - s.frame.width - 12, height: 18))
            s.frame.origin = NSPoint(x: W - M - s.frame.width + 5, y: y + 4)   // the switch draws 5 pt inside its frame
            s.target = self; s.action = #selector(clipboardChanged(_:))
            s.refusesFirstResponder = true
            s.tag = p.tag
            s.setAccessibilityLabel("\(section), \(L("Clipboard"))")
            addSubview(s)
            switches[k] = s
            y += Self.switchRowH
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func kind(_ tag: Int) -> Kind { tag == 0 ? .shot : .video }

    // Pop-up items, by tag: Desktop, the picked folder (while one is remembered), Other Location…, a line, None.
    private enum Item: Int { case desktop = 1, folder, other, notSaved }

    func refresh() {
        for k in Kind.allCases {
            let v = settings.get(k)
            let p = popups[k]!
            p.removeAllItems()
            func add(_ title: String, _ item: Item) {
                p.addItem(withTitle: title)
                p.lastItem?.tag = item.rawValue
            }
            add(L("Desktop"), .desktop)
            if let f = v.folder {
                add(FileManager.default.displayName(atPath: f), .folder)
                p.lastItem?.toolTip = f
            }
            add(L("Other Location…"), .other)
            p.menu?.addItem(.separator())
            add(L("None"), .notSaved)
            // «None» while the clipboard is off would lose every capture: greyed, as macOS greys what can't be chosen.
            p.menu?.item(withTag: Item.notSaved.rawValue)?.isEnabled = v.clipboard
            p.selectItem(withTag: v.place == .desktop ? Item.desktop.rawValue : v.place == .folder ? Item.folder.rawValue : Item.notSaved.rawValue)
            p.toolTip = v.place == .folder ? v.folder : nil
            let s = switches[k]!
            s.state = v.clipboard ? .on : .off
            // And the clipboard can't go off while nothing is saved.
            s.isEnabled = v.place != .notSaved
        }
    }

    @objc func placeChosen(_ p: NSPopUpButton) {
        let k = kind(p.tag)
        var v = settings.get(k)
        switch Item(rawValue: p.selectedTag()) {
        case .desktop: v.place = .desktop
        case .folder: v.place = .folder
        case .notSaved: v.place = .notSaved
        case .other:
            if let f = pickFolder(start: v.folder) {
                if f == desktop.standardizedFileURL.path { v.place = .desktop } else { v.place = .folder; v.folder = f }
            }
        default: break
        }
        settings.set(k, v)
        refresh()
    }

    @objc func clipboardChanged(_ s: NSSwitch) {
        let k = kind(s.tag)
        var v = settings.get(k)
        v.clipboard = s.state == .on
        settings.set(k, v)
        refresh()
    }

    /// The system's folder chooser; nil on Cancel. Its button is macOS's own «Choose».
    private func pickFolder(start: String?) -> String? {
        let o = NSOpenPanel()
        o.canChooseDirectories = true
        o.canChooseFiles = false
        o.canCreateDirectories = true
        o.allowsMultipleSelection = false
        o.prompt = L("Choose")
        o.directoryURL = start.flatMap { isFolder($0) ? URL(fileURLWithPath: $0) : nil } ?? desktop
        NSApp.activate(ignoringOtherApps: true)
        guard o.runModal() == .OK, let url = o.url else { return nil }
        return url.standardizedFileURL.path
    }
}
