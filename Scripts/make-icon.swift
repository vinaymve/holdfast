// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
// Regenerates Resources/Holdfast.icns:  swift Scripts/make-icon.swift && iconutil -c icns build/Holdfast.iconset -o Resources/Holdfast.icns
//
// The mark is an anchor ("hold fast") in ink on a paper tile with a vermilion ring: the same palette as the app (Theme.swift).
import AppKit

let paper = NSColor(srgbRed: 0xF5 / 255.0, green: 0xF2 / 255.0, blue: 0xEB / 255.0, alpha: 1)
let ink = NSColor(srgbRed: 0x1C / 255.0, green: 0x1A / 255.0, blue: 0x17 / 255.0, alpha: 1)
let vermilion = NSColor(srgbRed: 0xC8 / 255.0, green: 0x43 / 255.0, blue: 0x1F / 255.0, alpha: 1)

func draw(_ ctx: CGContext, size s: CGFloat) {
    // Tile
    let inset = s * 0.06
    let tile = CGPath(roundedRect: CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2),
                      cornerWidth: s * 0.225, cornerHeight: s * 0.225, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.02, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    ctx.setFillColor(paper.cgColor)
    ctx.addPath(tile)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(s * 0.052)
    ctx.setStrokeColor(ink.cgColor)
    ctx.setFillColor(ink.cgColor)

    // Shank, from the ring down to the bottom of the arms
    ctx.move(to: CGPoint(x: s * 0.5, y: s * 0.68))
    ctx.addLine(to: CGPoint(x: s * 0.5, y: s * 0.20))
    ctx.strokePath()
    // Stock
    ctx.move(to: CGPoint(x: s * 0.37, y: s * 0.58))
    ctx.addLine(to: CGPoint(x: s * 0.63, y: s * 0.58))
    ctx.strokePath()
    // Arms: a half circle whose ends rise straight up, so the join is smooth
    let center = CGPoint(x: s * 0.5, y: s * 0.42), radius = s * 0.22
    ctx.addArc(center: center, radius: radius, startAngle: .pi, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()
    // Flukes: a short rise then an arrowhead on each arm
    for x in [center.x - radius, center.x + radius] {
        ctx.move(to: CGPoint(x: x, y: center.y))
        ctx.addLine(to: CGPoint(x: x, y: s * 0.48))
        ctx.strokePath()
        ctx.move(to: CGPoint(x: x, y: s * 0.545))
        ctx.addLine(to: CGPoint(x: x - s * 0.045, y: s * 0.465))
        ctx.addLine(to: CGPoint(x: x + s * 0.045, y: s * 0.465))
        ctx.closePath()
        ctx.drawPath(using: .fillStroke)
    }

    // Ring drawn last so it sits cleanly over the top of the shank
    ctx.setStrokeColor(vermilion.cgColor)
    ctx.strokeEllipse(in: CGRect(x: s * 0.5 - s * 0.07, y: s * 0.68, width: s * 0.14, height: s * 0.14))
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = context
    draw(context.cgContext, size: CGFloat(size))
    context.flushGraphics()
    NSGraphicsContext.current = previous
    return rep.representation(using: .png, properties: [:])!
}

let dir = "build/Holdfast.iconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(size: base).write(to: URL(fileURLWithPath: "\(dir)/icon_\(base)x\(base).png"))
    try! render(size: base * 2).write(to: URL(fileURLWithPath: "\(dir)/icon_\(base)x\(base)@2x.png"))
}
