// Stills, names and the clipboard.
//
// Why it is built this way (macOS 27.2.1, measured 2026-11-14):
// - Stills are taken by Apple's own /usr/sbin/screencapture, run by this app: it is a ScreenCaptureKit
//   client itself, so the file is exactly what macOS's own screenshot writes (native pixels, the display's
//   colour profile, 144 dpi, the screenshot metadata), and the area crosshair and the window picker are
//   Apple's own (hover highlight, click, Esc, Space to switch). The Screen Recording grant and its monthly
//   reminder are this app's either way: macOS attributes the child's capture to the app that runs it
//   (OCR.app, which does the same, has its own entry in replayd's approvals, none for screencapture).
// - -x always, and the sound is played here as a system sound: such a sound follows the system's
//   "Play user interface sound effects" switch by itself (kAudioServicesPropertyIsUISound), the way the
//   shutter of macOS's own screenshot does, and stays silent while a recording runs.
// - Names are plain local time, "2026-11-14 05-47-12.png": the app writes its own files, so it names them.

import AppKit
import AudioToolbox

/// Runs screencapture with these arguments and a file path; true when the file exists after (Esc: no file).
func screencapture(_ args: [String], to file: URL) async -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = args + [file.path]
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        p.terminationHandler = { _ in c.resume() }
        do { try p.run() } catch { c.resume() }
    }
    return FileManager.default.fileExists(atPath: file.path)
}

enum Still {
    case area, window, screen

    /// screencapture's arguments. Area: selection first, Space switches to a window as in macOS's own
    /// ⇧⌘4. Window: windows only. -o: no window shadow in either. Screen: the display under the pointer.
    var arguments: [String] {
        switch self {
        case .area: return ["-i", "-x", "-o", "-J", "selection"]
        case .window: return ["-i", "-x", "-o", "-w"]
        case .screen: return ["-x", "-D", String(displayUnderPointer().number)]
        }
    }
}

/// The display under the pointer: its CGDirectDisplayID and screencapture's -D number, which counts
/// CGGetActiveDisplayList's order from 1 (the main display first).
func displayUnderPointer() -> (id: CGDirectDisplayID, number: Int) {
    let p = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    let id = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var list = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &list, &count)
    return (id, (list.firstIndex(of: id) ?? 0) + 1)
}

// MARK: names

let nameFormat: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")   // Western digits and this exact pattern in every language
    f.dateFormat = "yyyy-MM-dd HH-mm-ss"
    return f
}()

/// "2026-11-14 05-47-12.png", or "… (2).png", "… (3).png" when taken.
func freeName(in folder: URL, for date: Date, ext: String) -> URL {
    let base = nameFormat.string(from: date)
    var url = folder.appendingPathComponent("\(base).\(ext)")
    var n = 2
    while FileManager.default.fileExists(atPath: url.path) {
        url = folder.appendingPathComponent("\(base) (\(n)).\(ext)")
        n += 1
    }
    return url
}

var desktop: URL { FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0] }

/// Moves a finished file to its place under a free name. On the same volume this is a rename.
func deliver(_ temp: URL, date: Date, ext: String) throws -> URL {
    let dest = freeName(in: desktop, for: date, ext: ext)
    try FileManager.default.moveItem(at: temp, to: dest)
    return dest
}

// MARK: clipboard

/// One item, so a paste gives one thing: the file (Finder and other file-aware apps take it, with its name)
/// and, for a picture, the picture itself (Telegram, Notes, Messages, browsers take that). The PNG is the
/// file's own bytes, colour profile included. TIFF, for apps that read only that, is made when one asks.
/// Each new capture replaces what was there.
final class Clipboard: NSObject, NSPasteboardItemDataProvider {
    let pasteboard: NSPasteboard
    private var png: Data?

    init(_ pasteboard: NSPasteboard) { self.pasteboard = pasteboard }

    func put(_ file: URL, picture: Bool) {
        let item = NSPasteboardItem()
        let url = file as NSURL
        for type in url.writableTypes(for: pasteboard) {
            // NSURL hands most types over as a string or raw data; setPropertyList would wrap those in a
            // plist that readers don't parse (measured: the file URL then read back as nothing).
            switch url.pasteboardPropertyList(forType: type) {
            case let s as String: item.setString(s, forType: type)
            case let d as Data: item.setData(d, forType: type)
            case let v?: item.setPropertyList(v, forType: type)
            default: break
            }
        }
        png = nil
        if picture, let data = try? Data(contentsOf: file) {
            png = data
            item.setData(data, forType: .png)
            item.setDataProvider(self, forTypes: [.tiff])
        }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .tiff, let png, let image = NSBitmapImageRep(data: png) else { return }
        item.setData(image.tiffRepresentation ?? Data(), forType: .tiff)
    }
}

// MARK: sound

/// macOS's own screenshot sound, as a UI sound: silent when the system's sound effects are off.
let shutter: SystemSoundID = {
    var id: SystemSoundID = 0
    let url = URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif")
    AudioServicesCreateSystemSoundID(url as CFURL, &id)
    return id
}()
