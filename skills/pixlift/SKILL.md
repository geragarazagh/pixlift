---
name: pixlift
description: "Runs offline OCR on images, captures headless macOS screenshots, samples screen pixel hex colours, and checks Pixlift settings via pixlift-cli. Use when extracting text from images, grabbing a screenshot, reading a pixel colour, or customizing Pixlift."
license: MIT
compatibility: "macOS 13 or later (Apple Silicon) with Pixlift installed (brew install geragarazagh/tap/pixlift or /Applications/Pixlift.app)."
---

# Pixlift

Drives Pixlift (`pixlift-cli`) from the command line for offline Vision OCR, headless screenshots, screen pixel sampling, and status checks.

## Locate the CLI

Check in order; use the first that exits 0:

```sh
pixlift-cli --version
/Applications/Pixlift.app/Contents/MacOS/Pixlift --version
```

If neither exists, tell the user how to install it (`brew install geragarazagh/tap/pixlift`) and stop.

## Common tasks

1. **Extract text (or QR payload) from image files**:
   ```sh
   pixlift-cli ocr image.png
   pixlift-cli ocr page1.png page2.png
   ```
2. **Take a full-screen screenshot** (writes a Display P3 PNG and prints its path; never overwrites an existing file):
   ```sh
   pixlift-cli screenshot
   pixlift-cli screenshot -o /tmp/screen.png --display 1
   ```
3. **Sample a screen pixel colour as `#RRGGBB`**:
   ```sh
   pixlift-cli color 400 300
   ```
4. **Check settings and permissions**:
   ```sh
   pixlift-cli status --json
   ```

## Notes

- `screenshot` and `color` require Screen Recording permission for the terminal or host app running the command; `ocr` on local image files needs no Screen Recording permission.
- Rebuilding from source: clone `https://github.com/geragarazagh/pixlift`, read `AGENTS.md`, edit Swift files, and run `./build` (requires only Xcode Command Line Tools for ad-hoc builds).
