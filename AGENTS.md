# AGENTS.md — OCR

Offline macOS screen & image text recognition (plus QR fallback) using Apple Vision in plain Swift + AppKit. No Xcode project; `./build` compiles directly with `swiftc`.

## Architecture

- `main.swift` — Vision recognition (`RecognizeTextRequest` on macOS 15+, legacy `VNRecognizeTextRequest` on 13–14), mixed-script second pass, large-image tiling (>2000 × 1300 px), `Gate` concurrency cap (≤2), barcode/QR fallback, warm-up self-test, `answersForItself()`.
- `cli.swift` — `ocr-cli` (`[-q] FILE...`, `--file`, `--selftest`, `status`, `--version`, `--help`).
- `window.swift` — shared 340 pt fixed settings window, Carbon hot-key recorder, Open at Login helper.
- `updates.swift` — Sparkle 2.10.1 updater.

## Build & Test

- `./build` — builds ad-hoc signed `OCR.app` (`-target arm64-apple-macos13.0`). Works with Xcode Command Line Tools alone (`iconutil` fallback). Full Xcode is used for `Assets.car` (required when `SIGN_ID` is set).
- `./test` — runs Vision self-test card and 3 barcode/QR cases against `OCR.app`.

## Invariants

- **Concurrency**: never allow more than 2 simultaneous Vision requests (`Gate`), or Swift's thread pool deadlocks on 4-core Macs.
- **Security**: `--file` / file CLI refuses to run when `answersForItself()` is true.
- **Customizing locally**: edit recognition or tiling rules in `main.swift`, run `./build`, replace `/Applications/OCR.app`. Ad-hoc re-signing resets Screen Recording TCC approval.
