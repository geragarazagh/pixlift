<picture><source media="(prefers-color-scheme: dark)" srcset="docs/icon-dark.png"><img src="docs/icon.png" width="128" alt="Pixlift icon"></picture>

# Pixlift: screenshots, screen recording, text and color for Mac

Free, open source app for macOS that takes screenshots and records the screen, one keyboard shortcut for each: a selected area, a selected window, the whole screen, a recording of the whole screen with its sound. Each capture is saved to the Desktop or a chosen folder, copied to the clipboard, or both, as set in its window for screenshots and for recordings. Two more shortcuts copy the text of any area of the screen and the color of any pixel.

Copy Text is the recognition of [OCR](https://github.com/geragarazagh/ocr) and Copy Color the picker of [#HEX](https://github.com/geragarazagh/hex): the author’s single-function apps, which stay available on their own.

Apple silicon, macOS 13 or later. Signed with a Developer ID and notarized by Apple.

<picture><source media="(prefers-color-scheme: dark)" srcset="docs/scene.webp"><img src="docs/scene-light.webp" alt="Preview with the Wright brothers’ telegram of 17 December 1903; beside it a note holding a capture of the whole screen, which holds the same screen again, smaller each time; on the Desktop five captures named by their time, 2025-12-17 17-25-00 to 17-25-59"></picture>

The Wright brothers’ telegram of 17 December 1903 in Preview. Option-Command-7 took an area of it, and the note got the capture from the clipboard; then Option-Command-9 took the whole screen four times, each pasted over the last. Here every capture is also saved to the Desktop, named by the time it was taken.

## Install

**Mac** (Apple silicon, macOS 13 or later): download [`Pixlift.dmg`](https://github.com/geragarazagh/pixlift/releases/latest/download/Pixlift.dmg) (1.6 MB), open it and drag `Pixlift.app` to Applications. Later versions arrive through Check for Updates.

Or with [Homebrew](https://brew.sh):

```sh
brew install geragarazagh/tap/pixlift
```

## Use

- Option-Command-7: Capture Selected Portion. Drag over an area; Space switches to a window, Esc cancels.
- Option-Command-8: Capture Selected Window. The window under the pointer is highlighted, a click takes it, without its shadow.
- Option-Command-9: Capture Entire Screen, the screen under the pointer.
- Option-Command-0: Record Entire Screen. The same shortcut stops the recording.
- Option-Command-6: Copy Text. Drag over an area, and its text is on the clipboard.
- Option-Command-5: Copy Color. A click on any pixel copies its HEX code, for example `#EFEFEF`.

Where a capture goes is set in the window, for screenshots and for recordings apart, in the words of the Screenshot app of macOS: Save to the Desktop, another folder (Other Location…) or None, and Clipboard on or off. One of the two always stays on. Files are named by time, `2026-11-14 05-47-12.png` and `2026-11-14 05-47-12.mp4`; on the clipboard each new capture replaces the last one.

At first the settings follow the screenshots of macOS: saved where macOS saves them (the Desktop, unless another place is chosen in its Screenshot app), clipboard off. Updated from 0.1, Pixlift keeps saving to the Desktop and copying, as before.

The window has Check for Updates, the six shortcuts, where screenshots and recordings go, Open at Login and Quit. Opening the app shows its window. Closing the window leaves the shortcuts working, with nothing in the Dock or the menu bar.

## For advanced users and language models

The screenshots of macOS (Shift-Command-3, 4 and 5) go either to a file or to the clipboard, one at a time, and a recording takes several clicks. Pixlift gives each kind of capture one shortcut and can do both: the file in a folder and the same capture on the clipboard. It has no capture engine of its own: screenshots are made by macOS’s own `screencapture`, recordings by ScreenCaptureKit, text by Apple’s Vision, color by the color sampler of macOS. Everything runs on the Mac, offline. No editor, no history, no cloud, no logs.

### What it does

- Six system-wide shortcuts, Option-Command-7, 8, 9, 0, 6 and 5 by default, each changed in the window. The first four are named as macOS names the same actions.
- Two settings for screenshots and two for recordings: Save to (the Desktop, a folder chosen with Other Location…, or None) and Clipboard. A choice that would turn both off is greyed out, so a capture always goes somewhere. A file name already taken gets ` (2)`, ` (3)` and so on.
- The first launch reads the place of macOS’s own screenshots from `com.apple.screencapture` (`location`, and on macOS 27 `location-screenshot` and `location-screenrecording`); with none set it is the Desktop. Screenshots that macOS sends to its clipboard start as copied, not saved. After that the settings are Pixlift’s own. A Mac updated from 0.1 starts with both on and the Desktop.
- The clipboard holds one item: the file and, for a screenshot, the picture itself as PNG. An app that takes files gets the file with its name, an app that takes pictures gets the picture. A recording is copied as its file. A screenshot that is not saved goes as the picture alone. A recording that is not saved is kept in `~/Library/Caches/com.geragaraza.pixlift/Clipboard`, because a recording is pasted as a file; it is deleted once it is off the clipboard and more than an hour old.
- Recording: the whole screen under the pointer, with the pointer, the Mac’s sound and the microphone. Nothing counts down, and Pixlift draws nothing over the screen or in the menu bar.
- Nothing in the Dock or the menu bar. Open at Login stays off until it is turned on.

### How it works

- Screenshots are taken by `/usr/sbin/screencapture`, the program behind the screenshots of macOS itself, with its crosshair and its window picker. The PNG is what macOS’s own screenshot would be: the display’s own pixels, its color profile, 144 dpi on a Retina display. Pixlift then names the file and saves it, copies it, or both, as set.
- The shutter sound is the one of macOS and follows its Play user interface sound effects setting; it is silent while a recording runs.
- Recording runs on ScreenCaptureKit: the picture and the Mac’s sound from it, the microphone through AVFoundation, mixed into one sound track, because players and messengers play only the first track. The app’s own sounds are left out.
- The MP4 is H.264 (High profile) at the display’s own resolution, with a variable frame rate up to the display’s refresh rate: frames come only when the screen changes, so a still screen costs almost nothing. Colors bt709, sound AAC, 48 kHz stereo. The bit rate is about twice the one macOS uses for its own recordings, about 20 Mbit/s for a 3456 x 2234 display.
- A recording is written to a temporary file and moved to its place when it stops. Quitting the app during a recording finishes the file first.
- Copy Text is the engine of [OCR](https://github.com/geragarazagh/ocr): the area is read by Apple’s Vision on the Mac, in every language Vision has on the installed macOS; an area with no text in it gives what its QR code or other barcode encodes.
- Copy Color is the picker of [#HEX](https://github.com/geragarazagh/hex): the loupe is `NSColorSampler`, the color is converted to sRGB and copied in upper case as `#RRGGBB`.
- The shortcuts are Carbon hot keys (`RegisterEventHotKey`), which need no Accessibility. They are stored as physical keys, so they work in every keyboard layout.
- macOS does not report a shortcut another app already holds, and then both apps act on one press. While OCR or #HEX runs with the same shortcut, that row shows Used by OCR or Used by #HEX, and Pixlift leaves the key to it until it quits.

### Questions

#### Which permissions does it need, and why?

Screen & System Audio Recording (Screen Recording before macOS 15), for screenshots, recordings and Copy Text. macOS asks at the first press that needs it; until it is allowed, each such press shows an alert with a button to System Settings. Microphone, for recordings: macOS asks at the first recording, and when it is not allowed, a recording can go on with the Mac’s sound only. Copy Color needs none.

#### Why does macOS ask again about screen recording?

Since macOS 15, macOS itself asks from time to time whether an app may go on recording the screen. It asks this of every app except Apple’s own, and a Developer ID does not change it.

#### Can the files go to another folder, or only to the clipboard?

Yes, either, set apart for screenshots and recordings: Save to the Desktop, any folder (Other Location…) or None, and Clipboard on or off. One of the two always stays on. A chosen folder that is gone, such as a disk that was unplugged, gets the capture on the Desktop instead, with an alert that says so.

#### Does it work without internet?

Yes. Capture, recording and recognition never use the network; the only network call is the daily update check. Links in the window open only on a click.

#### Does it run on Intel Macs?

No. Apple silicon only, macOS 13 or later.

### Updates

Once a day the app reads the feed of its latest GitHub release (`appcast.xml`) through Sparkle. Nothing about the Mac is sent. When a newer version is out, a window shows it with Install Update, Remind Me Later and Skip This Version; nothing is downloaded before Install Update. Check for Updates in the window checks at once.

The feed and the disk image are signed with an EdDSA key, and Sparkle installs only an app that carries the same Developer ID signature.

### Settings and removal

It stores the shortcuts, where captures go, whether it has been opened and has asked for screen access before, and the time of the last update check in the defaults of `com.geragaraza.pixlift`, and Vision’s compiled model and a recording that is only on the clipboard in `~/Library/Caches/com.geragaraza.pixlift`. The captures themselves are the files where they were saved.

To remove Pixlift: Quit in its window, move `Pixlift.app` to the Trash, delete that cache folder and clear its settings with this command:

```sh
defaults delete com.geragaraza.pixlift
```

Installed with Homebrew, this command quits it and removes the app, its settings and the cache:

```sh
brew uninstall --zap pixlift
```

Either way, its Screen & System Audio Recording and Microphone entries are removed in System Settings, Privacy & Security.

### From Terminal

This command prints the text of pictures instead of copying it:

```sh
/Applications/Pixlift.app/Contents/MacOS/Pixlift --file a.png b.png
```

### Details

- Version: 0.2.
- Bundle ID: `com.geragaraza.pixlift`.
- Download: `Pixlift.dmg`, 1.6 MB.
- Requires: Apple silicon, macOS 13 or later.
- Permissions: Screen & System Audio Recording, Microphone. Network: only the update check.
- Signed with a Developer ID and notarized by Apple.
- Code: Swift with AppKit, ScreenCaptureKit, AVFoundation and Vision, about 2,100 lines, and the Sparkle framework for updates.
- License: MIT. Sparkle is MIT too; its license comes with the app and is in `THIRD-PARTY-LICENSES.md`.

### Build

Needs Xcode 26 or later in Applications: the Swift compiler, and actool with Icon Composer for the light and dark icon. The first build downloads the Sparkle framework from its release.

    ./build

Search terms: screenshot app for Mac, screen recorder for Mac, save screenshot and copy to clipboard, screenshot to Desktop and clipboard, screen recording with system audio and microphone, record screen to MP4, keyboard shortcut screenshot, window screenshot without shadow, OCR, copy text from screen, color picker, ScreenCaptureKit.
