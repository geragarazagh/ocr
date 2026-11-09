// OCR app icon. Since 2026-11-09 an Icon Composer icon (macOS 26+ switches it with the theme, Apple's way):
// this draws only the picture, light.png and dark.png, 1024 px, transparent; the plate is the system's own fill.
// dark: the scene is copied from a screen recording of /usr/sbin/screencapture -i on a dark page: words of
// text, a thin solid white selection over a faint white wash, the black crosshair with a grey halo
// and ring, and the white size readout. 456 x 345: consecutive digits, and about the box's ratio.
// Usage: ./build runs this: icon <dir> writes <dir>/light.png and <dir>/dark.png.

import AppKit
import CoreText

func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
}

func capsule(_ c: CGContext, _ r: CGRect, _ col: CGColor) {
    c.setFillColor(col); c.addPath(CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)); c.fillPath()
}

// light: the same scene as macOS draws it over a white page, measured 2026-11-09 from his screen recording of
// screencapture -i on white (2x): no border, only a grey wash (#E2E2E2 over white = black at 11.4 %); the
// crosshair #383838 without a halo, its ring a light disc (#DCDCDC, black at 13.7 %) edged at #9D9D9D (38 %)
// about 3 px wide; the digits black. Sizes are the dark ones: arm 23 px there = 118 here, ring 12.4 px = 64.
func draw(_ c: CGContext, light: Bool) {
    // The plate is the system's fill now; the old 824 px plate becomes the whole 1024 canvas.
    c.scaleBy(x: 1024 / 824, y: 1024 / 824); c.translateBy(x: -100, y: -100)

    // Text: four lines of words.
    let words: [[CGFloat]] = [[118, 74, 150, 92], [96, 168, 70, 104], [140, 84, 186], [176, 98]]
    for (i, line) in words.enumerated() {
        var x: CGFloat = 262
        for w in line { capsule(c, CGRect(x: x, y: 650 - CGFloat(i) * 96, width: w, height: 42), rgb(0x8E8E93)); x += w + 22 }
    }

    // Selection.
    let sel = CGRect(x: 236, y: 412, width: 380, height: 300)
    if light {
        c.setFillColor(rgb(0x000000, 0.114)); c.fill(sel)
    } else {
        c.setFillColor(rgb(0xFFFFFF, 0.18)); c.fill(sel)
        c.setStrokeColor(rgb(0xFFFFFF)); c.setLineWidth(10); c.stroke(sel)
    }

    // Crosshair at the dragged corner.
    let p = CGPoint(x: sel.maxX, y: sel.minY), arm: CGFloat = 118
    c.setLineCap(.butt)
    if light {
        let r: CGFloat = 64
        c.setFillColor(rgb(0x000000, 0.137)); c.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        c.setStrokeColor(rgb(0x000000, 0.384)); c.setLineWidth(15)
        c.strokeEllipse(in: CGRect(x: p.x - r + 7.5, y: p.y - r + 7.5, width: 2 * r - 15, height: 2 * r - 15))
        c.setStrokeColor(rgb(0x383838)); c.setLineWidth(10)
        c.move(to: CGPoint(x: p.x - arm, y: p.y)); c.addLine(to: CGPoint(x: p.x + arm, y: p.y))
        c.move(to: CGPoint(x: p.x, y: p.y - arm)); c.addLine(to: CGPoint(x: p.x, y: p.y + arm)); c.strokePath()
    } else {
        c.setStrokeColor(rgb(0xA8A8AC, 0.6)); c.setLineWidth(30)
        c.strokeEllipse(in: CGRect(x: p.x - arm * 0.42, y: p.y - arm * 0.42, width: arm * 0.84, height: arm * 0.84))
        for (w, col) in [(CGFloat(24), rgb(0xD1D1D6, 0.9)), (10, rgb(0x000000))] {
            c.setStrokeColor(col); c.setLineWidth(w)
            c.move(to: CGPoint(x: p.x - arm, y: p.y)); c.addLine(to: CGPoint(x: p.x + arm, y: p.y))
            c.move(to: CGPoint(x: p.x, y: p.y - arm)); c.addLine(to: CGPoint(x: p.x, y: p.y + arm)); c.strokePath()
        }
    }

    // Size readout.
    let font = NSFont.monospacedDigitSystemFont(ofSize: 74, weight: .semibold)
    for (i, t) in ["456", "345"].enumerated() {
        let a = NSAttributedString(string: t, attributes: light ? [.font: font, .foregroundColor: NSColor.black]
            : [.font: font, .foregroundColor: NSColor.white, .strokeColor: NSColor.black, .strokeWidth: -4])
        c.saveGState(); c.textMatrix = .identity
        c.textPosition = CGPoint(x: p.x + 44, y: p.y - 108 - CGFloat(i) * 76)
        CTLineDraw(CTLineCreateWithAttributedString(a), c); c.restoreGState()
    }
}

for light in [true, false] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.cgContext.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    draw(NSGraphicsContext.current!.cgContext, light: light)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1] + (light ? "/light.png" : "/dark.png")))
}
