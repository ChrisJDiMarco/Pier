// Renders Pier's app icon at every size macOS needs and writes an .iconset folder.
// Usage: swift Tools/make_icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Apple's icon grid: 824/1024 body with ~185/1024 corner radius, centered.
    let inset = s * 100 / 1024
    let body = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = body.width * 0.2245
    let squircle = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    // Drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: color(0x000000, 0.35).cgColor)
    color(0x000000).setFill()
    squircle.fill()
    ctx.restoreGState()

    // Sky: dusk indigo down to a warm horizon.
    ctx.saveGState()
    squircle.addClip()
    let waterTop = body.minY + body.height * 0.4
    let sky = CGRect(x: body.minX, y: waterTop, width: body.width, height: body.maxY - waterTop)
    NSGradient(colors: [color(0x23275E), color(0x6A4C9C), color(0xE2735A), color(0xFBBF6E)],
               atLocations: [0, 0.45, 0.82, 1], colorSpace: .sRGB)!
        .draw(in: sky, angle: -90)

    // Setting sun, half below the horizon, with a soft glow.
    let sunD = body.width * 0.3
    let sunCenter = CGPoint(x: body.midX + body.width * 0.08, y: waterTop + sunD * 0.12)
    let glowR = sunD * 1.35
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [color(0xFFE6B0, 0.85).cgColor, color(0xFFC98A, 0.35).cgColor,
                                   color(0xFFC98A, 0).cgColor] as CFArray,
                          locations: [0, 0.45, 1])!
    ctx.drawRadialGradient(glow, startCenter: sunCenter, startRadius: 0, endCenter: sunCenter, endRadius: glowR,
                           options: [])
    color(0xFFF2D2).setFill()
    NSBezierPath(ovalIn: CGRect(x: sunCenter.x - sunD / 2, y: sunCenter.y - sunD / 2, width: sunD, height: sunD)).fill()

    // Water.
    let water = CGRect(x: body.minX, y: body.minY, width: body.width, height: waterTop - body.minY)
    NSGradient(colors: [color(0x3A3F7A), color(0x1E2150)], atLocations: [0, 1], colorSpace: .sRGB)!
        .draw(in: water, angle: -90)
    for i in 0..<4 {
        let y = waterTop - body.height * (0.035 + CGFloat(i) * 0.045)
        let w = body.width * (0.26 - CGFloat(i) * 0.04)
        color(0xFFD9A0, 0.55 - CGFloat(i) * 0.1).setFill()
        NSBezierPath(roundedRect: CGRect(x: sunCenter.x - w / 2, y: y, width: w, height: body.height * 0.012),
                     xRadius: s * 0.004, yRadius: s * 0.004).fill()
    }

    // Pier silhouette: deck plus pilings, receding toward the sun.
    color(0x14163A).setFill()
    let deckY = waterTop + body.height * 0.015
    let deck = NSBezierPath()
    deck.move(to: CGPoint(x: body.minX, y: deckY))
    deck.line(to: CGPoint(x: body.midX + body.width * 0.04, y: deckY + body.height * 0.035))
    deck.line(to: CGPoint(x: body.midX + body.width * 0.04, y: deckY + body.height * 0.052))
    deck.line(to: CGPoint(x: body.minX, y: deckY + body.height * 0.075))
    deck.close()
    deck.fill()
    for i in 0..<6 {
        let t = CGFloat(i) / 5
        let x = body.minX + body.width * (0.06 + t * 0.48)
        let top = deckY + body.height * (0.065 - t * 0.03)
        let w = body.width * (0.022 - t * 0.01)
        NSBezierPath(rect: CGRect(x: x, y: body.minY + body.height * (0.3 + t * 0.06), width: w, height: top - body.minY - body.height * (0.3 + t * 0.06))).fill()
    }

    // Glass dock shelf with four app dots.
    let shelf = CGRect(x: body.minX + body.width * 0.14, y: body.minY + body.height * 0.085,
                       width: body.width * 0.72, height: body.height * 0.17)
    let shelfPath = NSBezierPath(roundedRect: shelf, xRadius: shelf.height * 0.36, yRadius: shelf.height * 0.36)
    color(0xFFFFFF, 0.24).setFill()
    shelfPath.fill()
    color(0xFFFFFF, 0.55).setStroke()
    shelfPath.lineWidth = max(1, s * 0.004)
    shelfPath.stroke()
    let dotColors: [UInt32] = [0x5AC8FA, 0x34C759, 0xFF9F0A, 0xFF375F]
    let tile = shelf.height * 0.62
    let gap = (shelf.width - tile * 4) / 5
    for (i, c) in dotColors.enumerated() {
        let r = CGRect(x: shelf.minX + gap + CGFloat(i) * (tile + gap), y: shelf.midY - tile / 2, width: tile, height: tile)
        NSGradient(colors: [color(c), color(c).blended(withFraction: 0.35, of: .black)!], atLocations: [0, 1],
                   colorSpace: .sRGB)!.draw(in: NSBezierPath(roundedRect: r, xRadius: tile * 0.26, yRadius: tile * 0.26),
                                            angle: -90)
    }

    // Top gloss.
    NSGradient(colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)], atLocations: [0, 1], colorSpace: .sRGB)!
        .draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    ctx.restoreGState()

    // Hairline edge.
    color(0xFFFFFF, 0.18).setStroke()
    squircle.lineWidth = max(1, s * 0.003)
    squircle.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    try render(px).write(to: output.appendingPathComponent("\(name).png"))
}
print("Wrote \(sizes.count) icons to \(output.path)")
