// Holdfast. Copyright (C) 2026 Holdfast contributors. GPL-3.0-or-later (see LICENSE).
// Derived from SelfControl by Charlie Stigler et al. (https://github.com/SelfControlApp/selfcontrol); rewritten in Swift with changes.
// Regenerates Resources/Holdfast.icns:  swift Scripts/make-icon.swift && iconutil -c icns build/Holdfast.iconset -o Resources/Holdfast.icns
import AppKit

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s))
    image.lockFocus()
    let inset = s * 0.06
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.225, yRadius: s * 0.225)
    NSGradient(colors: [NSColor(red: 0.13, green: 0.20, blue: 0.42, alpha: 1), NSColor(red: 0.20, green: 0.45, blue: 0.95, alpha: 1)])!
        .draw(in: path, angle: -60)
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.5, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "lock.shield.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        symbol.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.set()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.draw(in: NSRect(x: (s - symbol.size.width) / 2, y: (s - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height))
    }
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

let dir = "build/Holdfast.iconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(size: base).write(to: URL(fileURLWithPath: "\(dir)/icon_\(base)x\(base).png"))
    try! render(size: base * 2).write(to: URL(fileURLWithPath: "\(dir)/icon_\(base)x\(base)@2x.png"))
}
