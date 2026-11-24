---
name: ocr
description: "Extracts text (or QR code payloads) from local image files offline using Apple Vision via ocr-cli. Use when running offline OCR on screenshots, scans, or images on a Mac with OCR installed, or customizing OCR."
license: MIT
compatibility: "macOS 13 or later (Apple Silicon) with OCR installed (brew install geragarazagh/tap/ocr or /Applications/OCR.app)."
---

# OCR

Runs Apple Vision offline text and QR-code recognition on local image files via `ocr-cli` (no Screen Recording permission needed for local files).

## Locate the CLI

Check in order; use the first that exits 0:

```sh
ocr-cli --version
/Applications/OCR.app/Contents/MacOS/OCR --version
```

If neither exists, tell the user how to install it (`brew install geragarazagh/tap/ocr`) and stop.

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
