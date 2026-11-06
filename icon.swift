// OCR app icon, drawn with Core Graphics at 1024 px on Apple's macOS grid (824 px plate).
// Drawn dark on purpose: macOS 27's automatic darkening of
// plain .icns icons is a hidden heuristic (it skipped icons with white or black details in tests).
// The scene is copied from a screen recording of /usr/sbin/screencapture -i: words of
// text, a thin solid white selection over a faint white wash, the black crosshair with a grey halo
// and ring, and the white size readout. 456 x 345: consecutive digits, and about the box's ratio.
// Usage: swiftc icon.swift -o /tmp/icon && /tmp/icon out.png   (./build does this)

import AppKit
import CoreText

func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}

func capsule(_ c: CGContext, _ r: CGRect, _ col: CGColor) {
    c.setFillColor(col); c.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)); c.fillPath()
}

func draw(_ c: CGContext) {
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    c.saveGState()
    c.addPath(CGPath(roundedRect: plate, cornerWidth: plate.width * 0.225, cornerHeight: plate.width * 0.225, transform: nil)); c.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(0x2C2C2E), rgb(0x0F0F10)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(g, start: CGPoint(x: 0, y: plate.maxY), end: CGPoint(x: 0, y: plate.minY), options: [])
    c.restoreGState()

    // Text: four lines of words.
    let words: [[CGFloat]] = [[118, 74, 150, 92], [96, 168, 70, 104], [140, 84, 186], [176, 98]]
    for (i, line) in words.enumerated() {
        var x: CGFloat = 262
        for w in line { capsule(c, CGRect(x: x, y: 650 - CGFloat(i) * 96, width: w, height: 42), rgb(0x8E8E93)); x += w + 22 }
    }

    // Selection.
    let sel = CGRect(x: 236, y: 412, width: 380, height: 300)
    c.setFillColor(rgb(0xFFFFFF, 0.18)); c.fill(sel)
    c.setStrokeColor(rgb(0xFFFFFF)); c.setLineWidth(10); c.stroke(sel)

    // Crosshair at the dragged corner.
    let p = CGPoint(x: sel.maxX, y: sel.minY), arm: CGFloat = 118
    c.setLineCap(.butt)
    c.setStrokeColor(rgb(0xA8A8AC, 0.6)); c.setLineWidth(30)
    c.strokeEllipse(in: CGRect(x: p.x - arm * 0.42, y: p.y - arm * 0.42, width: arm * 0.84, height: arm * 0.84))
    for (w, col) in [(CGFloat(24), rgb(0xD1D1D6, 0.9)), (10, rgb(0x000000))] {
        c.setStrokeColor(col); c.setLineWidth(w)
        c.move(to: CGPoint(x: p.x - arm, y: p.y)); c.addLine(to: CGPoint(x: p.x + arm, y: p.y))
        c.move(to: CGPoint(x: p.x, y: p.y - arm)); c.addLine(to: CGPoint(x: p.x, y: p.y + arm)); c.strokePath()
    }

    // Size readout.
    let font = NSFont.monospacedDigitSystemFont(ofSize: 74, weight: .semibold)
    for (i, t) in ["456", "345"].enumerated() {
        let a = NSAttributedString(string: t, attributes: [.font: font, .foregroundColor: NSColor.white, .strokeColor: NSColor.black, .strokeWidth: -4])
        c.saveGState(); c.textMatrix = .identity
        c.textPosition = CGPoint(x: p.x + 44, y: p.y - 108 - CGFloat(i) * 76)
        CTLineDraw(CTLineCreateWithAttributedString(a), c); c.restoreGState()
    }
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current!.cgContext.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))
draw(NSGraphicsContext.current!.cgContext)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
