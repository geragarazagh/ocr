// Command line interface for OCR: extract text (or QR code) from image files offline via Apple Vision.
// Run as ocr-cli (symlink to OCR.app/Contents/MacOS/OCR) or as OCR with flags:
//
//   ocr-cli [-q|--quiet] FILE...     prints extracted text of each image file to stdout
//   ocr-cli --file FILE...           backwards-compatible alias
//   ocr-cli --selftest               runs Vision model warm-up and self-test card
//   ocr-cli status [--json]          prints version, running state and Screen Recording status
//   ocr-cli --version | --help

import AppKit

private let ocrCliName = "ocr-cli"

private let ocrAppBundle: Bundle = {
    // executableURL, not argv[0]: run by name from PATH (the Homebrew symlink) argv[0] is the bare name, and the bundle
    // three levels above it is the current folder's, not the app's (measured 2026-11-23: version 0, settings unread).
    let real = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    let appURL = real.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return Bundle(url: appURL) ?? .main
}()

private func ocrFail(_ s: String) -> Never {
    FileHandle.standardError.write(Data((s + "\n").utf8))
    exit(1)
}

private func ocrJSON(_ obj: Any) -> Never {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
          let text = String(data: data, encoding: .utf8) else { ocrFail("Could not encode JSON.") }
    print(text)
    exit(0)
}

private func ocrRunning() -> Bool {
    guard let id = ocrAppBundle.bundleIdentifier else { return false }
    return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { $0.processIdentifier != getpid() }
}

// Terminal modes for testing (files and --selftest): never touch the clipboard.
// The file modes act only for a caller that answers for itself (Pixlift's security pass 2026-11-14): started by another
// program as an app, they would read pictures with OCR's own folder permissions and hand their text to that program.
private func runFiles(_ paths: [String], quiet: Bool) -> Never {
    guard !paths.isEmpty else { ocrFail("No file given.") }
    let sem = DispatchSemaphore(value: 0)
    var failed = false
    Task.detached {
        for (i, path) in paths.enumerated() {
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                FileHandle.standardError.write(Data("unreadable: \(path)\n".utf8))
                failed = true
                continue
            }
            let t0 = Date()
            if paths.count > 1 { print((i > 0 ? "\n" : "") + "==> \(path) <==") }
            do { print(try await textFor(img)) } catch {
                FileHandle.standardError.write(Data("error (\(path)): \(error)\n".utf8))
                failed = true
            }
            if !quiet {
                FileHandle.standardError.write(Data(String(format: "%@ %.2fs\n", path, Date().timeIntervalSince(t0)).utf8))
            }
        }
        sem.signal()
    }
    sem.wait()
    exit(failed ? 1 : 0)
}

@MainActor func runOCRCLI(_ rawArgs: [String]) -> Bool {
    let exe = ocrAppBundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? "OCR"
    let named = URL(fileURLWithPath: rawArgs[0]).lastPathComponent != exe
    let rest = Array(rawArgs.dropFirst())
    let usage = """
    Usage: \(ocrCliName) [-q|--quiet] FILE...     extracts text (or QR code) from image files
           \(ocrCliName) --file FILE...           alias for FILE...
           \(ocrCliName) --selftest               runs Vision model warm-up self-test
           \(ocrCliName) status [--json]          prints version, running state and Screen Recording status
           \(ocrCliName) --version | --help
    """
    let guiFlags: Set<String> = ["--login", "--background"]
    guard let first = rest.first else {
        if named { print(usage); exit(0) }
        return false
    }

    switch first {
    case "--help", "-h":
        print(usage); exit(0)
    case "--version", "-V":
        let v = ocrAppBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        print("OCR \(v)"); exit(0)
    case "--selftest":
        let sem = DispatchSemaphore(value: 0)
        var failed = false
        Task.detached {
            let t0 = Date()
            let engine = Engine(); await engine.warmUp()
            if let f = await engine.failure { print(f, String(format: "%.1fs", Date().timeIntervalSince(t0))); failed = true }
            else { print("ok", String(format: "%.1fs", Date().timeIntervalSince(t0))) }
            sem.signal()
        }
        sem.wait()
        exit(failed ? 1 : 0)
    case "status":
        if answersForItself() { ocrFail("\(ocrCliName) runs from a terminal or script.") }
        let tail = Array(rest.dropFirst())
        let json = tail == ["--json"]
        guard tail.isEmpty || json else { ocrFail(usage) }
        let version = ocrAppBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let running = ocrRunning()
        let screen = CGPreflightScreenCaptureAccess()
        if json { ocrJSON(["version": version, "running": running, "screenAccess": screen]) }
        print("version: \(version)\nrunning: \(running ? "yes" : "no")\nscreenAccess: \(screen ? "yes" : "no")")
        exit(0)
    case "--file":
        if answersForItself() { ocrFail("--file works only from a terminal") }
        runFiles(Array(rest.dropFirst()), quiet: false)
    case "-q", "--quiet":
        if answersForItself() { ocrFail("\(ocrCliName) works only from a terminal") }
        runFiles(Array(rest.dropFirst()), quiet: true)
    default:
        // A bare argument from a terminal or script is a file, found or not: a missing one is an error, never a launch
        // of the app's window (2026-11-24: `OCR missing.png` from a terminal opened the GUI and its first-launch window).
        // Started as an app (LaunchServices, a login item) it is not ours to read: that goes on to the GUI below.
        if !first.hasPrefix("-") && (named || !answersForItself()) {
            if answersForItself() { ocrFail("\(ocrCliName) works only from a terminal") }
            var quiet = false, files: [String] = []
            for a in rest {
                if a == "-q" || a == "--quiet" { quiet = true }
                else { files.append(a) }
            }
            runFiles(files, quiet: quiet)
        }
        if named || (first.hasPrefix("--") && !guiFlags.contains(first)) { ocrFail(usage) }
        return false
    }
}
