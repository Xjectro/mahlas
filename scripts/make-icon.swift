// Renders the Mahlas app icon (crimson squircle + white domino mask) into an
// .iconset folder. Usage: swift make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 body with shadow room
    let inset = s * 0.1
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.225
    let squircle = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    ctx.addPath(squircle); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    let colors = [NSColor(red: 1, green: 0.30, blue: 0.36, alpha: 1).cgColor,
                  NSColor(red: 0.88, green: 0.11, blue: 0.18, alpha: 1).cgColor,
                  NSColor(red: 0.30, green: 0.02, blue: 0.06, alpha: 1).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    // top sheen
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                           locations: [0, 1])!
    ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: body.midX, y: body.maxY), startRadius: 0,
                           endCenter: CGPoint(x: body.midX, y: body.maxY), endRadius: body.width * 0.8, options: [])

    // Domino mask (flipped coordinates: y up)
    let m = body.insetBy(dx: body.width * 0.17, dy: body.width * 0.17)
    func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: m.minX + m.width * x, y: m.maxY - m.height * y) }
    let mask = CGMutablePath()
    mask.move(to: P(0, 0.28))
    mask.addQuadCurve(to: P(0.5, 0.36), control: P(0.25, 0.12))
    mask.addQuadCurve(to: P(1, 0.28), control: P(0.75, 0.12))
    mask.addQuadCurve(to: P(0.62, 0.82), control: P(1.02, 0.8))
    mask.addQuadCurve(to: P(0.5, 0.66), control: P(0.54, 0.66))
    mask.addQuadCurve(to: P(0.38, 0.82), control: P(0.46, 0.66))
    mask.addQuadCurve(to: P(0, 0.28), control: P(-0.02, 0.8))
    mask.closeSubpath()
    mask.addEllipse(in: CGRect(x: m.minX + m.width * 0.16, y: m.maxY - m.height * 0.54, width: m.width * 0.24, height: m.height * 0.16))
    mask.addEllipse(in: CGRect(x: m.minX + m.width * 0.60, y: m.maxY - m.height * 0.54, width: m.width * 0.24, height: m.height * 0.16))
    ctx.setShadow(offset: .zero, blur: s * 0.04, color: NSColor(red: 1, green: 0.8, blue: 0.8, alpha: 0.6).cgColor)
    ctx.addPath(mask)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
