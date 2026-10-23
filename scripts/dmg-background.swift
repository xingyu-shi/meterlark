import AppKit

// Finder icon positions in dmg-settings.py use this 720 × 460 point canvas.
// Render both resolutions so text and line work stay sharp on Retina displays.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let width = 720
let height = 460

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        calibratedRed: CGFloat((hex >> 16) & 255) / 255,
        green: CGFloat((hex >> 8) & 255) / 255,
        blue: CGFloat(hex & 255) / 255,
        alpha: alpha
    )
}

let ink = color(0x24272A)
let muted = color(0x696E70)
let green = color(0x268854)

func text(_ value: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight, tint: NSColor) {
    (value as NSString).draw(at: point, withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: tint
    ])
}

func line(_ points: [NSPoint], tint: NSColor, width: CGFloat) {
    let path = NSBezierPath()
    path.lineWidth = width
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.move(to: points[0])
    for point in points.dropFirst() { path.line(to: point) }
    tint.setStroke()
    path.stroke()
}

func lens(in rect: NSRect, tint: NSColor, stroke: CGFloat) {
    let arm = rect.width * 0.24
    for (x, y, dx, dy) in [
        (rect.minX, rect.minY, arm, arm),
        (rect.maxX, rect.minY, -arm, arm),
        (rect.maxX, rect.maxY, -arm, -arm),
        (rect.minX, rect.maxY, arm, -arm)
    ] {
        line([NSPoint(x: x + dx, y: y), NSPoint(x: x, y: y), NSPoint(x: x, y: y + dy)], tint: tint, width: stroke)
    }
}

for scale in [1, 2] {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width * scale, pixelsHigh: height * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Cannot create installer artwork context")
    }
    bitmap.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    context.cgContext.translateBy(x: 0, y: CGFloat(height))
    context.cgContext.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)

    // Soft silver surface, with a quiet oversized version of the brand lens.
    let canvas = NSRect(x: 0, y: 0, width: width, height: height)
    NSGradient(starting: color(0xFBFBF8), ending: color(0xECEEE9))!.draw(in: canvas, angle: 90)
    lens(in: NSRect(x: 562, y: 51, width: 208, height: 208), tint: color(0xDADFD8, alpha: 0.55), stroke: 14)

    let mark = NSBezierPath(roundedRect: NSRect(x: 40, y: 32, width: 28, height: 28), xRadius: 8, yRadius: 8)
    color(0x17191C).setFill()
    mark.fill()
    lens(in: NSRect(x: 47, y: 39, width: 14, height: 14), tint: color(0xF2F0EA), stroke: 2.2)
    color(0xF2F0EA).setFill()
    NSBezierPath(roundedRect: NSRect(x: 52.3, y: 44.3, width: 3.4, height: 3.4), xRadius: 0.7, yRadius: 0.7).fill()
    text("Meterlark", at: NSPoint(x: 78, y: 31), size: 23, weight: .semibold, tint: ink)
    text("macOS  /  Apple silicon", at: NSPoint(x: 514, y: 41), size: 11, weight: .medium, tint: muted)

    text("Your AI usage. In focus.", at: NSPoint(x: 40, y: 99), size: 34, weight: .bold, tint: ink)
    text("Drag Meterlark into Applications to install.", at: NSPoint(x: 42, y: 147), size: 15, weight: .regular, tint: muted)

    // A single installation surface leaves the live Finder icons unobstructed.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x343C32, alpha: 0.06)
    shadow.shadowBlurRadius = 18
    shadow.shadowOffset = NSSize(width: 0, height: 4)
    shadow.set()
    color(0xFFFFFF, alpha: 0.92).setFill()
    NSBezierPath(roundedRect: NSRect(x: 28, y: 199, width: 664, height: 198), xRadius: 26, yRadius: 26).fill()
    NSGraphicsContext.restoreGraphicsState()

    // Open lens corners frame the source and destination without fake buttons.
    for x in [CGFloat(106), CGFloat(466)] {
        lens(in: NSRect(x: x, y: 211, width: 148, height: 146), tint: color(0xE2E7DF), stroke: 1.5)
    }
    line([NSPoint(x: 298, y: 278), NSPoint(x: 420, y: 278)], tint: color(0xC4D7C5), width: 1.5)
    color(0xEDF5EC).setFill()
    NSBezierPath(ovalIn: NSRect(x: 336, y: 254, width: 48, height: 48)).fill()
    line([NSPoint(x: 350, y: 278), NSPoint(x: 370, y: 278)], tint: green, width: 2.5)
    line([NSPoint(x: 363, y: 271), NSPoint(x: 370, y: 278), NSPoint(x: 363, y: 285)], tint: green, width: 2.5)
    text("DRAG TO INSTALL", at: NSPoint(x: 313, y: 318), size: 10, weight: .medium, tint: green)

    green.setFill()
    NSBezierPath(ovalIn: NSRect(x: 42, y: 426, width: 6, height: 6)).fill()
    text("Then open Meterlark from Applications.", at: NSPoint(x: 58, y: 420), size: 12, weight: .medium, tint: muted)
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Cannot encode installer artwork")
    }
    let suffix = scale == 1 ? "" : "@2x"
    let name = "background\(suffix).png"
    try png.write(to: output.appendingPathComponent(name), options: .atomic)
}
