import AppKit

let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    NSColor(calibratedRed: 0.075, green: 0.09, blue: 0.09, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 196, yRadius: 196).fill()
    NSColor(calibratedRed: 0.32, green: 0.73, blue: 0.61, alpha: 0.18).setStroke()
    let halo = NSBezierPath(ovalIn: NSRect(x: 190, y: 190, width: 644, height: 644)); halo.lineWidth = 3; halo.stroke()
    context.translateBy(x: 475, y: 325); context.scaleBy(x: 14, y: 14)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: -9, y: 0, width: 18, height: 17)).fill()
    NSBezierPath(roundedRect: NSRect(x: -10, y: 11, width: 20, height: 15), xRadius: 6, yRadius: 6).fill()
    let ears = NSBezierPath()
    ears.move(to: NSPoint(x: -10, y: 18)); ears.line(to: NSPoint(x: -9, y: 30)); ears.line(to: NSPoint(x: -2, y: 24)); ears.close()
    ears.move(to: NSPoint(x: 10, y: 18)); ears.line(to: NSPoint(x: 9, y: 30)); ears.line(to: NSPoint(x: 2, y: 24)); ears.close(); ears.fill()
    let tail = NSBezierPath(); tail.move(to: NSPoint(x: 6, y: 3)); tail.curve(to: NSPoint(x: 16, y: 11), controlPoint1: NSPoint(x: 23, y: -3), controlPoint2: NSPoint(x: 22, y: 9)); tail.lineWidth = 4; tail.lineCapStyle = .round; NSColor.white.setStroke(); tail.stroke()
    NSColor.black.setFill()
    NSBezierPath(ovalIn: NSRect(x: -5.5, y: 18, width: 2, height: 2.4)).fill()
    NSBezierPath(ovalIn: NSRect(x: 3.5, y: 18, width: 2, height: 2.4)).fill()
    NSGraphicsContext.restoreGraphicsState()
    let png = bitmap.representation(using: .png, properties: [:])!
    let names: [String]
    switch size {
    case 16: names = ["icon_16x16"]
    case 32: names = ["icon_16x16@2x", "icon_32x32"]
    case 64: names = ["icon_32x32@2x"]
    case 128: names = ["icon_128x128"]
    case 256: names = ["icon_128x128@2x", "icon_256x256"]
    case 512: names = ["icon_256x256@2x", "icon_512x512"]
    default: names = ["icon_512x512@2x"]
    }
    for name in names { try png.write(to: URL(fileURLWithPath: destination + "/" + name + ".png")) }
}
