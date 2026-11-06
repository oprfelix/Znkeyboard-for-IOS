// ZnKeyboard's iOS app icon, from the Android launcher icon's artwork: a blue card with a sparkle popping up from a pale keyboard,
// like a key preview. The blue gradient and sparkle match the macOS and Windows apps' icon; the
// keyboard marks this one as the input method.
//
// Usage: copy to main.swift, build with swiftc, and run with the path of AppIcon-1024.png
import AppKit

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

/// A four-point star pinched to [waist] between its points.
func sparkle(center: NSPoint, radius: CGFloat, waist: CGFloat) -> NSBezierPath {
    let tips = [NSPoint(x: 0, y: -radius), NSPoint(x: radius, y: 0), NSPoint(x: 0, y: radius), NSPoint(x: -radius, y: 0)]
    let path = NSBezierPath()
    path.move(to: NSPoint(x: center.x + tips[0].x, y: center.y + tips[0].y))
    for i in 0..<4 {
        let tip = tips[(i + 1) % 4]
        let c = NSPoint(x: center.x + (tips[i].x + tip.x) * waist / radius * 0.5, y: center.y + (tips[i].y + tip.y) * waist / radius * 0.5)
        path.curve(to: NSPoint(x: center.x + tip.x, y: center.y + tip.y), controlPoint1: c, controlPoint2: c)
    }
    path.close()
    return path
}

// Geometry on a flipped 1024 canvas (origin top-left); the artwork spans x and y 128...896.
let baseRect = NSRect(x: 128, y: 470, width: 768, height: 426)
let cardRect = NSRect(x: 300, y: 128, width: 424, height: 470)

/// One row of six keys over a spacebar.
func keyPaths() -> [NSBezierPath] {
    let area = NSRect(x: 196, y: 640, width: 632, height: 200)
    let gap: CGFloat = 26, columns = 6
    let height = (area.height - gap) / 2
    let width = (area.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
    var paths = (0..<columns).map { column in
        rounded(NSRect(x: area.minX + CGFloat(column) * (width + gap), y: area.minY, width: width, height: height), 18)
    }
    paths.append(rounded(NSRect(x: area.minX + width + gap, y: area.minY + height + gap, width: area.width - 2 * (width + gap), height: height), 18))
    return paths
}

func sparkles() -> [NSBezierPath] {
    [sparkle(center: NSPoint(x: 500, y: 365), radius: 150, waist: 30), sparkle(center: NSPoint(x: 640, y: 215), radius: 48, waist: 11)]
}

func withShadow(alpha: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = rgb(30, 70, 160, alpha)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func drawColor() {
    let base = rounded(baseRect, 80)
    withShadow(alpha: 0.14) { rgb(214, 228, 255).setFill(); base.fill() }
    NSGradient(starting: rgb(232, 240, 255), ending: rgb(196, 216, 255))!.draw(in: base, angle: -60)
    rgb(255, 255, 255, 0.75).setStroke()
    base.lineWidth = 6
    base.stroke()
    rgb(104, 150, 240).setFill()
    keyPaths().forEach { $0.fill() }

    let card = rounded(cardRect, 76)
    withShadow(alpha: 0.25) { rgb(42, 112, 255).setFill(); card.fill() }
    NSGradient(starting: rgb(42, 112, 255), ending: rgb(118, 168, 255))!.draw(in: card, angle: -50)
    rgb(255, 255, 255, 0.35).setStroke()
    card.lineWidth = 10
    card.stroke()
    rgb(255, 255, 255, 0.95).setFill()
    sparkles().forEach { $0.fill() }
}

/// One colour with transparency, for themed icons: the keyboard half strength with its keys cut
/// out, a clear gap around the card, and the sparkles cut out of the card.
func drawMonochrome() {
    let context = NSGraphicsContext.current!
    NSColor.white.withAlphaComponent(0.5).setFill()
    rounded(baseRect, 80).fill()
    context.compositingOperation = .clear
    keyPaths().forEach { $0.fill() }
    rounded(cardRect.insetBy(dx: -22, dy: -22), 98).fill()
    context.compositingOperation = .sourceOver
    NSColor.white.setFill()
    rounded(cardRect, 76).fill()
    context.compositingOperation = .clear
    sparkles().forEach { $0.fill() }
    context.compositingOperation = .sourceOver
}

/// [draw] on a [pixels]-square bitmap, the 1024 design scaled by [scale] about the centre so the
/// artwork stays inside the adaptive icon's safe zone.
func png(pixels: Int, scale: CGFloat, _ draw: () -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    cg.interpolationQuality = .high
    cg.translateBy(x: 0, y: CGFloat(pixels))
    cg.scaleBy(x: CGFloat(pixels) / 1024, y: -CGFloat(pixels) / 1024)
    cg.translateBy(x: 512, y: 512)
    cg.scaleBy(x: scale, y: scale)
    cg.translateBy(x: -512, y: -512)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// iOS rounds the corners itself and wants no transparency, so the artwork sits on opaque white.
let artwork = NSBitmapImageRep(data: png(pixels: 1024, scale: 0.86, drawColor))!.cgImage!
let canvas = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
canvas.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
canvas.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
canvas.draw(artwork, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
try! NSBitmapImageRep(cgImage: canvas.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
