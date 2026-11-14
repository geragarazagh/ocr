// Pictures for ./test: pictures <dir> writes mixed.png (text beside a QR at 2 % contrast, 250 on 255, which Vision
// still decodes), faint.png (that QR alone) and solid.png (a black QR alone). Payload and text are in ./test.
import AppKit
import CoreImage

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let payload = "https://example.com/not-what-was-selected"
let gen = CIFilter(name: "CIQRCodeGenerator")!
gen.setValue(Data(payload.utf8), forKey: "inputMessage")
let qrImage = gen.outputImage!.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
let ctx = CIContext()

func draw(text: String?, qrShade: CGFloat, to name: String) {
    let size = CGSize(width: 1400, height: 520)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
    if let text {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
            .draw(in: NSRect(x: 40, y: 40, width: 900, height: 440))
    }
    // The QR's dark modules in a near-white grey, its light ones in white.
    let tinted = qrImage.applyingFilter("CIFalseColor", parameters: [
        "inputColor0": CIColor(red: qrShade, green: qrShade, blue: qrShade), "inputColor1": CIColor.white])
    let cg = ctx.createCGImage(tinted, from: tinted.extent)!
    NSGraphicsContext.current!.cgContext.draw(cg, in: CGRect(x: 980, y: 60, width: tinted.extent.width, height: tinted.extent.height))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
}

draw(text: "Run this in Terminal:\nbrew install geragarazagh/tap/ocr", qrShade: 250 / 255, to: "mixed.png")
draw(text: nil, qrShade: 250 / 255, to: "faint.png")
draw(text: nil, qrShade: 0, to: "solid.png")
