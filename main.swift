// OCR: a hot key -> Apple's own selection crosshair -> text (or QR) to the clipboard.
// Apple parts only: /usr/sbin/screencapture for the selection, Vision for recognition.
// No network, no logs. The only things it keeps are the chosen hot key and Vision's model cache.
//
// Self-test / test on files (prints instead of copying):
//   OCR.app/Contents/MacOS/OCR --selftest
//   OCR.app/Contents/MacOS/OCR --file a.png b.png
//
// Why it is built this way (macOS 27.0.1, measured):
// - The legacy VNRecognizeTextRequest path stalls and fails on macOS 27 (TRex #92,
//   macshot #439); the Swift RecognizeTextRequest API exists only from macOS 15. So: Swift API
//   from 15, legacy on 13 and 14. Below 13 Vision has no Cyrillic and no language detection.
// - No list of languages anywhere: Vision's automatic detection picks the language line by line,
//   and with it on the language list changes nothing (every language, 4 looks, measured). What
//   Apple adds to Vision works here without a new build.
// - Detection takes one language per line, so a word in another script inside a Latin or Cyrillic
//   line comes out as confident nonsense ("The word low means hello"). Vision's other models
//   point at such words, and Vision's detection on the word alone has the last word.
// - Vision compiles its model per program into ~/Library/Caches/<id>/com.apple.e5rt.e5bundlecache.
//   The first request after that takes ~33 s, and a bad compile can make every later
//   request silently drop whole lines. So the model is warmed and checked at launch on a
//   known card; on failure the cache is removed and compiled again.
// - .fast recognition has no Cyrillic ("CKa4aki yepe3"), so there is no .fast fallback.
// - usesLanguageCorrection must stay on: off, Russian turns into noise.
// - 1.5x upscaling gave the fewest errors (code braces, small text); a 1x pass runs too
//   and wins only if it found clearly more, as insurance against dropped lines.

import AppKit
import Carbon.HIToolbox
import CoreImage
import Vision

// MARK: recognition

/// A line as Vision read it, whichever API did. Boxes are normalized, origin at the bottom left.
struct Line {
    var text: String
    var box: CGRect
    var boxOf: (Range<String.Index>) -> CGRect?
}

func alnum(_ lines: [Line]) -> Int {
    lines.map(\.text).joined().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
}

let ciContext = CIContext()

func upscaled(_ image: CGImage, _ scale: CGFloat) -> CGImage {
    let f = CIFilter(name: "CILanczosScaleTransform")!
    f.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
    f.setValue(scale, forKey: kCIInputScaleKey)
    let out = f.outputImage!
    return ciContext.createCGImage(out, from: out.extent.integral) ?? image
}

/// The legacy API gets one queue of its own, for the reason below.
let visionQueue = DispatchQueue(label: "vision")

func onVisionQueue<T>(_ work: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { c in
        visionQueue.async { c.resume(with: Result { try work() }) }
    }
}

/// Vision blocks the thread it runs on. Enough requests at once use up Swift's thread pool, which is as
/// wide as the Mac has cores, and then all of them hang for good: measured on 4 cores on macOS 13 and
/// 15, never seen on 12. So never more than two at a time, on any Mac.
actor Gate {
    // A stalled request keeps its slot, so a new one enters after waiting 15 s however full it looks.
    private var free = 2
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        if free > 0 { free -= 1; return }
        await withCheckedContinuation { c in
            waiting.append(c)
            Task { try? await Task.sleep(nanoseconds: 15_000_000_000); self.expire() }
        }
    }
    func leave() {
        if waiting.isEmpty { free += 1 } else { waiting.removeFirst().resume() }
    }
    private func expire() {
        if !waiting.isEmpty { waiting.removeFirst().resume() }
    }
}
let gate = Gate()

struct VisionStalled: Error {}

/// Seconds a request may take. Long while models compile at launch (30 s and more each), short after.
/// Vision has stalled for good once in about 3 000 requests here, with nothing running: without a
/// limit the app then ignores its hot key until restarted. A stalled request is abandoned.
nonisolated(unsafe) var visionLimit: UInt64 = 300

/// `language` nil: Vision detects it, line by line. Otherwise that language's model reads everything.
func read(_ image: CGImage, language: String? = nil) async throws -> [Line] {
    let limit = visionLimit
    return try await withCheckedThrowingContinuation { (c: CheckedContinuation<[Line], Error>) in
        let once = Once()
        Task.detached {
            do { let lines = try await readNow(image, language: language); if once.first() { c.resume(returning: lines) } }
            catch { if once.first() { c.resume(throwing: error) } }
        }
        Task.detached {
            try? await Task.sleep(nanoseconds: limit * 1_000_000_000)
            if once.first() { c.resume(throwing: VisionStalled()) }
        }
    }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool { lock.lock(); defer { lock.unlock() }; defer { done = true }; return !done }
}

func readNow(_ image: CGImage, language: String?) async throws -> [Line] {
    if #available(macOS 15, *) {
        await gate.enter()
        defer { Task { await gate.leave() } }
        var r = RecognizeTextRequest()
        r.recognitionLevel = .accurate
        r.usesLanguageCorrection = true
        r.minimumTextHeightFraction = 0
        r.automaticallyDetectsLanguage = language == nil
        if let language { r.recognitionLanguages = [Locale.Language(identifier: language)] }
        return try await r.perform(on: image).compactMap { o in
            guard let t = o.topCandidates(1).first else { return nil }
            return Line(text: t.string, box: o.boundingBox.cgRect, boxOf: { t.boundingBox(for: $0)?.boundingBox.cgRect })
        }
    }
    return try await onVisionQueue {
        let r = VNRecognizeTextRequest()
        r.recognitionLevel = .accurate
        r.usesLanguageCorrection = true
        r.minimumTextHeight = 0
        r.automaticallyDetectsLanguage = language == nil
        if let language { r.recognitionLanguages = [language] }
        try VNImageRequestHandler(cgImage: image).perform([r])
        return (r.results ?? []).compactMap { o in
            guard let t = o.topCandidates(1).first else { return nil }
            return Line(text: t.string, box: o.boundingBox, boxOf: { (try? t.boundingBox(for: $0))?.boundingBox })
        }
    }
}

func visionLanguages() -> [String] {
    if #available(macOS 15, *) {
        var r = RecognizeTextRequest()
        r.recognitionLevel = .accurate
        return r.supportedRecognitionLanguages.map(\.maximalIdentifier)
    }
    let r = VNRecognizeTextRequest()
    r.recognitionLevel = .accurate
    return ((try? r.supportedRecognitionLanguages()) ?? []).map { Locale.Language(identifier: $0).maximalIdentifier }
}

/// One language per model outside the Latin + Cyrillic one, which detection reads anyway. Models go
/// by script, so a script Apple adds gets its pass by itself. Chinese, Cantonese and Japanese share one.
let otherModels: [String] = {
    var seen: Set<String> = ["Latn", "Cyrl"]
    return visionLanguages().filter { id in
        let parts = id.split(separator: "-").map(String.init)
        guard parts.count > 1 else { return false }
        return seen.insert(["Hans", "Hant", "Jpan", "Hani"].contains(parts[1]) ? "Han" : parts[1]).inserted
    }
}()

/// Letters from outside the Latin, Greek and Cyrillic blocks (the Latin + Cyrillic model's own).
func isForeign(_ c: Character) -> Bool {
    c.isLetter && !c.unicodeScalars.allSatisfy { $0.value < 0x530 || (0x1E00...0x1FFF).contains($0.value) }
}

/// Runs of foreign letters in a line, with the brackets around them; spaces inside a run stay in it.
func foreignRuns(_ text: String) -> [Range<String.Index>] {
    let open = "([{«（「", close = ")]}»）」"
    var runs: [Range<String.Index>] = []
    var start: String.Index?, end = text.startIndex
    func flush() {
        guard var s = start else { return }
        if s > text.startIndex, open.contains(text[text.index(before: s)]) { s = text.index(before: s) }
        if end < text.endIndex, close.contains(text[end]) { end = text.index(after: end) }
        runs.append(s..<end); start = nil
    }
    for i in text.indices {
        if isForeign(text[i]) {
            if start == nil { start = i }
            end = text.index(after: i)
        } else if !text[i].isWhitespace {
            flush()
        }
    }
    flush()
    return runs
}

/// Does a reading fill the box it came from? Characters of every script Vision has are at least a
/// third of the line's height wide. A few letters over a long stretch are noise: detection does
/// see kana in a crop of plain English now and then, and this is what stops it (600 pictures).
func fits(_ word: String, _ box: CGRect, in image: CGImage) -> Bool {
    let width = box.width * CGFloat(image.width), height = box.height * CGFloat(image.height)
    return CGFloat(word.filter { !$0.isWhitespace }.count) * height * 1.5 >= width
}

func crop(_ image: CGImage, _ box: CGRect) -> CGImage? {
    let w = CGFloat(image.width), h = CGFloat(image.height)
    // Room above and below for detection; little sideways, or neighbours' letters get in.
    let padY = box.height * h * 0.35, padX = box.height * h * 0.12
    let r = CGRect(x: box.minX * w - padX, y: (1 - box.maxY) * h - padY, width: box.width * w + padX * 2, height: box.height * h + padY * 2)
    guard let piece = image.cropping(to: r.integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))) else { return nil }
    // Two small characters alone are too few pixels for detection to be sure of the script.
    return piece.height < 120 ? upscaled(piece, 120 / CGFloat(piece.height)) : piece
}

/// Puts words of another script back into lines Vision read as Latin or Cyrillic throughout.
/// The other models see such words in a Latin line, and every model reads Latin, so two independent
/// reads must agree: the model's and detection's on the word alone. No model but the main one reads
/// Cyrillic, so in a Cyrillic line the suspects are its words without Cyrillic letters, and
/// detection on the word alone decides by itself.
func restoreForeign(_ lines: [Line], in image: CGImage) async throws -> [String] {
    // All at once for speed, then in Vision's order so the same picture always gives the same text.
    // A model that fails here costs only its own second look; the capture stands.
    let reads = await withTaskGroup(of: (Int, [Line]).self) { group in
        for (i, model) in otherModels.enumerated() { group.addTask { (i, (try? await read(image, language: model)) ?? []) } }
        return await group.reduce(into: [(Int, [Line])]()) { $0.append($1) }.sorted { $0.0 < $1.0 }.map(\.1)
    }
    var fixes: [Int: [Fix]] = [:]
    for found in reads.flatMap({ $0 }) {
        for run in foreignRuns(found.text) {
            guard let box = found.boxOf(run), box.width > 0, box.height > 0,
                  let n = lines.indices.first(where: {
                      !lines[$0].text.contains(where: isForeign)
                          && lines[$0].box.intersection(box).height > box.height / 2 }),
                  // A model that doesn't know the script sees pieces of the word: the widest reading stays.
                  fixes[n, default: []].allSatisfy({ !$0.box.intersects(box) || $0.box.width < box.width }) else { continue }
            let word = String(found.text[run]).replacingOccurrences(of: "（", with: "(").replacingOccurrences(of: "）", with: ")")
            guard fits(word, box, in: image), let piece = crop(image, box), let alone = try? await read(piece).first?.text,
                  word.filter({ $0.isLetter && alone.contains($0) }).count * 2 >= word.filter(\.isLetter).count else { continue }
            fixes[n, default: []].removeAll { $0.box.intersects(box) }
            fixes[n, default: []].append(Fix(box: box, word: word, seen: Set(found.text.split(separator: " ").map(String.init))))
        }
    }
    let alones = await withTaskGroup(of: (Int, CGRect, String?).self) { group in
        for (n, line) in lines.enumerated() where line.text.contains(where: isCyr) && !line.text.contains(where: isForeign) {
            for box in suspects(line) where fixes[n, default: []].allSatisfy({ !$0.box.intersects(box) }) {
                group.addTask { (n, box, (try? await crop(image, box).asyncMap { try await read($0).first?.text }) ?? nil) }
            }
        }
        return await group.reduce(into: [(Int, CGRect, String?)]()) { $0.append($1) }.sorted { ($0.0, $0.1.minX) < ($1.0, $1.1.minX) }
    }
    for case let (n, box, alone?) in alones where alone.contains(where: isForeign) && !alone.contains(where: { $0.isLetter && !isForeign($0) }) && fits(alone, box, in: image) {
        // Alone it has no second model to agree with, so it must read the same at another size.
        guard let piece = crop(image, box), let again = try? await read(upscaled(piece, 1.5)).first?.text,
              alone.filter({ $0.isLetter && again.contains($0) }).count * 2 >= alone.filter(\.isLetter).count else { continue }
        fixes[n, default: []].append(Fix(box: box, word: alone.trimmingCharacters(in: CharacterSet.letters.union(CharacterSet(charactersIn: "()[]{}«»")).inverted), seen: []))
    }
    var texts = lines.map(\.text)
    for (n, f) in fixes { texts[n] = withWords(f, in: lines[n], aspect: CGFloat(image.width) / CGFloat(image.height)) }
    return texts
}

/// Boxes of the stretches of a Cyrillic line whose words have no Cyrillic letters.
func suspects(_ line: Line) -> [CGRect] {
    var out: [CGRect] = []
    var open = false
    for w in words(of: line) {
        if w.text.contains(where: isCyr) { open = false; continue }
        guard let b = w.box else { continue }
        if open, let last = out.popLast() { out.append(last.union(b)) } else { out.append(b) }
        open = true
    }
    return out
}

func words(of line: Line) -> [(text: String, box: CGRect?)] {
    var out: [(text: String, box: CGRect?)] = []
    var i = line.text.startIndex
    while i < line.text.endIndex {
        guard !line.text[i].isWhitespace else { i = line.text.index(after: i); continue }
        let from = i
        while i < line.text.endIndex, !line.text[i].isWhitespace { i = line.text.index(after: i) }
        out.append((String(line.text[from..<i]), line.boxOf(from..<i)))
    }
    return out
}

extension Optional {
    func asyncMap<T>(_ f: (Wrapped) async throws -> T) async rethrows -> T? {
        if let v = self { return try await f(v) }
        return nil
    }
}

struct Fix { var box: CGRect; var word: String; var seen: Set<String> }

/// A word under the box was a misreading of what the box holds and gives way, unless the other
/// model read that same word too: then it is real and the box was only too wide. Punctuation
/// after the misread word is real as well.
func withWords(_ fixes: [Fix], in line: Line, aspect: CGFloat) -> String {
    let all = words(of: line)
    var list = all.map { (text: $0.text, midX: $0.box?.midX ?? -1) }
    for f in fixes.sorted(by: { $0.box.minX > $1.box.minX }) {
        let under = list.indices.filter { f.box.minX...f.box.maxX ~= list[$0].midX && !f.seen.contains(list[$0].text) }
        // With nothing under it, a word Vision dropped needs a gap of at least a character's width between
        // two words: the other models also see things in plain spaces and past line ends (Thai in Russian).
        if under.isEmpty {
            guard let left = all.compactMap(\.box).filter({ $0.midX < f.box.midX }).map(\.maxX).max(),
                  let right = all.compactMap(\.box).filter({ $0.midX > f.box.midX }).map(\.minX).min(),
                  (right - left) * aspect > line.box.height * 1.3 else { continue }
        }
        let at = under.first ?? list.firstIndex { $0.midX > f.box.midX } ?? list.count
        var word = f.word
        if let last = under.last, let c = list[last].text.last, ",.:;!?".contains(c), word.last != c { word.append(c) }
        for u in under.reversed() { list.remove(at: u) }
        list.insert((word, f.box.midX), at: at)
    }
    return list.map(\.text).joined(separator: " ")
}

// MARK: big pictures

/// Vision shrinks a big picture before it looks: small text on a full screen loses lines and first
/// letters ("щё вчера", measured). Tiles are read at full size; a tile's line that the whole
/// picture missed is added, one it cut short loses to the longer reading. Vision's order stays.
func withTiles(_ lines: [Line], of image: CGImage) async throws -> [Line] {
    let w = image.width, h = image.height, tileW = 2000, tileH = 1300
    guard w > tileW || h > tileH else { return lines }
    var tiles: [CGRect] = []
    for y in stride(from: 0, to: max(h - tileH / 4, 1), by: tileH * 3 / 4) {
        for x in stride(from: 0, to: max(w - tileW / 4, 1), by: tileW * 3 / 4) {
            tiles.append(CGRect(x: x, y: y, width: min(tileW, w - x), height: min(tileH, h - y)))
        }
    }
    let found = try await withThrowingTaskGroup(of: (Int, [Line]).self) { group in
        for (i, t) in tiles.enumerated() {
            group.addTask {
                guard let c = image.cropping(to: t) else { return (i, []) }
                let map = { (b: CGRect) in CGRect(x: (t.minX + b.minX * t.width) / CGFloat(w), y: 1 - (t.minY + (1 - b.minY) * t.height) / CGFloat(h),
                                                  width: b.width * t.width / CGFloat(w), height: b.height * t.height / CGFloat(h)) }
                let inTile = (try? await read(upscaled(c, 1.5))) ?? []
                return (i, inTile.map { l in Line(text: l.text, box: map(l.box), boxOf: { l.boxOf($0).map(map) }) })
            }
        }
        return try await group.reduce(into: [(Int, [Line])]()) { $0.append($1) }.sorted { $0.0 < $1.0 }.flatMap(\.1)
    }
    func same(_ a: CGRect, _ b: CGRect) -> Bool {
        let i = a.intersection(b)
        return !i.isNull && i.width * i.height > 0.5 * min(a.width * a.height, b.width * b.height)
    }
    var out = lines
    for l in found.sorted(by: { $0.text.count > $1.text.count }) {
        if let n = out.firstIndex(where: { same($0.box, l.box) }) {
            if l.text.count > out[n].text.count { out[n] = l }
        } else {
            // A new line goes under the nearest line above it in its column.
            let above = out.lastIndex { $0.box.midY > l.box.midY && $0.box.minX < l.box.maxX && l.box.minX < $0.box.maxX }
            let at = above.map { $0 + 1 } ?? out.firstIndex { $0.box.midY < l.box.midY } ?? out.count
            out.insert(l, at: at)
        }
    }
    return out
}

/// Vision can fail once while it compiles a model ("Unable to compile network", macOS 15); once more is enough.
func readRetrying(_ image: CGImage) async throws -> [Line] {
    do { return try await read(image) } catch { return try await read(image) }
}

func recognizeBest(_ image: CGImage) async throws -> [String] {
    let big = upscaled(image, 1.5)
    async let bigLines = readRetrying(big)
    async let plainLines = readRetrying(image)
    let (a, b) = try await (bigLines, plainLines)
    if b.count > a.count && Double(alnum(b)) > Double(alnum(a)) * 1.15 { return b.map(\.text) }
    return try await restoreForeign(try await withTiles(a, of: image), in: big)
}

func barcodes(_ image: CGImage) async -> [String] {
    var payloads: [String] = []
    if #available(macOS 15, *) {
        await gate.enter()
        defer { Task { await gate.leave() } }
        let r = DetectBarcodesRequest()
        payloads = ((try? await r.perform(on: image)) ?? []).compactMap { $0.payloadString }
    } else {
        payloads = (try? await onVisionQueue {
            let r = VNDetectBarcodesRequest()
            try VNImageRequestHandler(cgImage: image).perform([r])
            return (r.results ?? []).compactMap { $0.payloadStringValue }
        }) ?? []
    }
    var seen = Set<String>()
    return payloads.filter { !$0.isEmpty && seen.insert($0).inserted }
}

// MARK: cleanup of Vision's typical slips

let latinToCyr: [Character: Character] = ["a": "а", "e": "е", "o": "о", "p": "р", "c": "с", "y": "у", "x": "х", "i": "і",
    "A": "А", "B": "В", "E": "Е", "K": "К", "M": "М", "H": "Н", "O": "О", "P": "Р", "C": "С", "T": "Т", "X": "Х", "I": "І"]
let cyrToLatin: [Character: Character] = Dictionary(latinToCyr.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })

func isCyr(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { (0x400...0x4FF).contains($0.value) } }
func isLat(_ c: Character) -> Bool { c.isLetter && c.unicodeScalars.allSatisfy { $0.value < 0x250 } }

// A word mixing Latin and Cyrillic letters is an OCR slip: bring lookalikes to the word's main script.
func fixWord(_ w: Substring) -> String {
    let cyr = w.filter(isCyr).count, lat = w.filter(isLat).count
    guard cyr > 0, lat > 0 else { return String(w) }
    let map = cyr >= lat ? latinToCyr : cyrToLatin
    let fixed = String(w.map { map[$0] ?? $0 })
    return (fixed.filter(isCyr).count == 0 || fixed.filter(isLat).count == 0) ? fixed : String(w)
}

// A one-letter Latin word before a Cyrillic one is a Cyrillic preposition ("request y гілці"). Lowercase
// only: "Vitamin C для" keeps its Latin C.
func fixLoneLetters(_ line: String) -> String {
    var words = line.components(separatedBy: " ")
    for i in words.indices.dropLast() where words[i].count == 1 && words[i + 1].first.map(isCyr) == true {
        if let c = words[i].first, c.isLowercase, let cyr = latinToCyr[c] { words[i] = String(cyr) }
    }
    return words.joined(separator: " ")
}

func clean(_ line: String) -> String {
    var out = ""
    var start = line.startIndex
    for i in line.indices where !line[i].isLetter {
        out += fixWord(line[start..<i]); out.append(line[i]); start = line.index(after: i)
    }
    out += fixWord(line[start...])
    out = fixLoneLetters(out)
    if out.contains(where: isCyr) { out = out.replacingOccurrences(of: "Nº", with: "№").replacingOccurrences(of: "N°", with: "№") }
    return out.trimmingCharacters(in: .whitespaces)
}

func textFor(_ image: CGImage) async throws -> String {
    async let codes = barcodes(image)
    async let lines = recognizeBest(image)
    let qr = await codes
    if !qr.isEmpty { return qr.joined(separator: "\n") }
    return try await lines.map(clean).joined(separator: "\n")
}

// MARK: self-test and cache repair

func card(_ text: String, points: CGFloat, canvas: CGSize? = nil) -> CGImage {
    let a = NSAttributedString(string: text, attributes: [.font: NSFont(name: "Helvetica Neue", size: points * 2) ?? NSFont.systemFont(ofSize: points * 2), .foregroundColor: NSColor.black])
    let s = a.boundingRect(with: NSSize(width: 6000, height: 6000), options: [.usesLineFragmentOrigin]).size
    let size = canvas ?? CGSize(width: s.width + 80, height: s.height + 60)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
    a.draw(in: NSRect(x: 40, y: 30, width: s.width + 2, height: s.height + 2))
    NSGraphicsContext.restoreGraphicsState()
    return rep.cgImage!
}

func distance(_ a: [Character], _ b: [Character]) -> Int {
    if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
    var p = Array(0...b.count)
    for i in 1...a.count {
        var c = [i]
        for j in 1...b.count { c.append(min(p[j] + 1, c[j - 1] + 1, p[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))) }
        p = c
    }
    return p[b.count]
}

// Lines for the self-test, one for each model; a model this system's Vision lacks is left out.
let cardText: String = {
    let scripts = Set(visionLanguages().compactMap { $0.split(separator: "-").dropFirst().first.map(String.init) })
    let others = [("Jpan", "今日は天気がとても良いので公園を散歩しました。"), ("Kore", "오늘 날씨가 정말 좋아서 공원을 산책했습니다."),
                  ("Thai", "วันนี้อากาศดีมาก เราจึงไปเดินเล่นในสวน"), ("Arab", "الطقس جميل جدا اليوم لذلك ذهبنا إلى الحديقة."),
                  ("Deva", "आज मौसम बहुत अच्छा है इसलिए हम घूमने गए।")]
    return (["Ещё вчера съёмка шла по плану, жёлтый свет.", "Їжак ґречно просив у бджоли ще трохи меду.",
             "The quick brown fox jumps over the lazy dog."] + others.filter { scripts.contains($0.0) }.map(\.1)).joined(separator: "\n")
}()

// Returns nil when Vision reads the card right, else a description of what went wrong.
func selfTest() async -> String? {
    // Two ordinary sizes. A card of small text on a whole empty screen was tried too: Vision itself misreads
    // it on macOS 13 and 15 (measured), so it warned at every launch about nothing.
    let cases = [(cardText, card(cardText, points: 13)), (cardText, card(cardText, points: 20))]
    for (n, (text, img)) in cases.enumerated() {
        let want = Array(text.replacingOccurrences(of: "\n", with: " "))
        let count = text.split(separator: "\n").count
        do {
            let got = try await recognizeBest(img)
            let text = Array(got.joined(separator: " "))
            let errors = distance(want, text)
            if got.count != count || errors > want.count / 20 {
                return "card \(n + 1) (\(img.width)x\(img.height)): \(got.count) of \(count) lines, \(errors) wrong characters\n" + got.joined(separator: "\n")
            }
        } catch {
            return "card \(n + 1): \(error)"
        }
    }
    return nil
}

func modelCache() -> URL {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "OCR").appendingPathComponent("com.apple.e5rt.e5bundlecache")
}

// MARK: capture

func captureSelection() async -> CGImage? {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: file) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-i", "-x", "-o", "-r", "-J", "selection", file.path]
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
        p.terminationHandler = { _ in c.resume() }
        do { try p.run() } catch { c.resume() }
    }
    // Read the bytes and decode now: an image made from the URL decodes lazily, after the defer
    // has deleted the file, and Vision then gets a blank picture (no text, no error). 2026-10-22.
    guard let data = try? Data(contentsOf: file), // Esc: no file
          let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
}

// MARK: app

actor Engine {
    var ready = false
    var failure: String?

    func warmUp() async {
        for attempt in 1...3 {
            if let problem = await selfTest() {
                failure = "Self-test failed (attempt \(attempt) of 3), model cache rebuilt.\n\(problem)"
                try? FileManager.default.removeItem(at: modelCache())
            } else {
                failure = nil; break
            }
        }
        ready = true
        visionLimit = 20
    }

    func run() async -> Result<String, Error> {
        if !ready { await warmUp() }
        guard let image = await captureSelection() else { return .success("") }
        do { return .success(try await textFor(image)) }
        catch {
            do { return .success(try await textFor(image)) } catch { return .failure(error) }
        }
    }
}

struct Message: Error, CustomStringConvertible { let description: String }

@MainActor final class App: NSObject, NSApplicationDelegate {
    let engine = Engine()
    var busy = false
    var window: AppWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        window = AppWindow(name: "OCR", github: "https://github.com/geragarazagh/ocr",
                           defaultShortcut: Shortcut(key: kVK_ANSI_6, mods: cmdKey | optionKey)) { [weak self] in self?.pressed() }
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        Task {
            await engine.warmUp()
            if let f = await engine.failure { report(L("OCR: self-test"), f) }
        }
    }

    func applicationShouldHandleReopen(_ a: NSApplication, hasVisibleWindows: Bool) -> Bool {
        window?.show()
        return false
    }

    // macOS asks only once, at the first launch. Whoever missed that gets this at every press.
    func askForScreenAccess() {
        busy = true   // a press while the alert is open must not open a second one
        defer { busy = false }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = L("OCR needs screen access")
        a.informativeText = L("Privacy & Security > Screen & System Audio Recording")
        a.addButton(withTitle: L("Open System Settings"))
        a.addButton(withTitle: L("Cancel"))
        a.window.level = .floating
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    func pressed() {
        guard !busy else { return }
        if !CGPreflightScreenCaptureAccess() {
            askForScreenAccess()
            return
        }
        busy = true
        Task {
            let result = await engine.run()
            busy = false
            switch result {
            case .success(let text) where text.isEmpty: break
            case .success(let text):
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
            case .failure(let e):
                report(L("OCR: recognition failed"), "\(e)")
            }
        }
    }
}

// MARK: main

startInBackgroundIfAtLogin()

let args = CommandLine.arguments
if args.count > 1 && ["--selftest", "--file"].contains(args[1]) {
    // Terminal modes for testing: never touch the clipboard.
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        if args[1] == "--selftest" {
            let t0 = Date()
            let engine = Engine(); await engine.warmUp()
            print(await engine.failure ?? "ok", String(format: "%.1fs", Date().timeIntervalSince(t0)))
        } else {
            for path in args.dropFirst(2) {
                guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("unreadable: \(path)"); continue }
                let t0 = Date()
                if args.count > 3 { print("==> \(path)") }
                do { print(try await textFor(img)) } catch { print("error: \(error)") }
                FileHandle.standardError.write(Data(String(format: "%@ %.2fs\n", path, Date().timeIntervalSince(t0)).utf8))
            }
        }
        sem.signal()
    }
    sem.wait()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
