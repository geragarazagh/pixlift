# AGENTS.md — Pixlift

Offline macOS screenshots, screen recording, OCR, and colour picker in plain Swift (AppKit, ScreenCaptureKit, Vision, AVFoundation). No Xcode project; `./build` compiles directly with `swiftc`.

## Architecture

- `main.swift` — entry point, `answersForItself()` guard, calls `runPixliftCLI`.
- `cli.swift` — `pixlift-cli` (`ocr`, `screenshot`, `color`, `status`, `--file`, `--version`, `--help`).
- `app.swift` — `App` delegate, hot-key actions, permission flows, shutter sound, OCR/colour handlers.
- `capture.swift` — `/usr/sbin/screencapture` wrapper, Display P3 naming (`yyyy-MM-dd HH-mm-ss`), clipboard `NSPasteboardItemDataProvider`.
- `destinations.swift` — per-kind (`shot`, `video`) save/clipboard settings and `com.apple.screencapture` one-time migration.
- `record.swift` — `ScreenCaptureKit` 60 fps H.264 recorder + system audio & mic mixer into AAC `.mp4`.
- `ocr.swift` — Vision text recognition (Swift API on macOS 15+, legacy on 13–14) + QR fallback.
- `window.swift` — fixed settings window, Carbon hot-key recorder, Open at Login helper.

## Build & Test

- `./build` — builds ad-hoc signed `Pixlift.app` (`-target arm64-apple-macos13.0`). Works with Xcode Command Line Tools alone (falls back to `iconutil`). Full Xcode is used for `Assets.car` (required when `SIGN_ID` is set).
- `./test docs/icon.png` — runs Pixlift's names, clipboard, destinations, sweep, fallback, audio-mix, and QR tests.

## Invariants

- **Security**: CLI modes check `answersForItself()` so another app cannot borrow Pixlift's Screen Recording or folder permissions via `open -n -a Pixlift --args …`.
- **Zero network**: no network calls except Sparkle's EdDSA-verified appcast.
- **Customizing locally**: edit source, run `./build`, replace `/Applications/Pixlift.app`. Ad-hoc re-signing resets Screen Recording TCC approval.
