---
name: ocr
description: "Extracts text (or QR code payloads) from local image files offline using Apple Vision via ocr-cli. Use when running offline OCR on screenshots, scans, or images on a Mac with OCR installed, or customizing OCR."
license: MIT
compatibility: "macOS 13 or later (Apple Silicon) with OCR installed (brew install geragarazagh/tap/ocr or /Applications/OCR.app)."
---

# OCR

Runs Apple Vision offline text and QR-code recognition on local image files via `ocr-cli` (no Screen Recording permission needed for local files).

## Locate the CLI

Check in order; use the first that exits 0. Use `--help`, never `--version`, and read the app's version from its Info.plist before running its binary: OCR before 0.5 has no command line at all, so it takes every flag (`--help` and `--version` alike) as a plain start and opens its window instead of failing.

```sh
ocr-cli --help
defaults read /Applications/OCR.app/Contents/Info CFBundleShortVersionString
/Applications/OCR.app/Contents/MacOS/OCR --help
```

`ocr-cli` exists only in versions that have the command line, so it is safe to try first. Run the third line only if the second prints 0.5 or newer; if it prints an older version, tell the user once to update OCR (Check for Updates in its menu, or `brew upgrade --cask geragarazagh/tap/ocr`) and stop. If none works, tell the user how to install it (`brew install geragarazagh/tap/ocr`) and stop.

## Common tasks

1. **Extract text from image files** (`-q` omits timing lines on stderr):
   ```sh
   ocr-cli -q screenshot.png
   ocr-cli -q page1.png page2.png
   ```
   The app binary itself takes the same arguments: `/Applications/OCR.app/Contents/MacOS/OCR -q screenshot.png`.
2. **Run Vision self-test** (verifies local model cache health):
   ```sh
   ocr-cli --selftest
   ```
3. **Check status**:
   ```sh
   ocr-cli status --json
   ```

## Rebuilding from source

Clone `https://github.com/geragarazagh/ocr`, read `AGENTS.md`, edit `main.swift`, and run `./build` (requires only Xcode Command Line Tools for ad-hoc builds).
