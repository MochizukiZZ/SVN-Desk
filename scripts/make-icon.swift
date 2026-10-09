import AppKit

let directory = CommandLine.arguments[1]
let iconset = URL(fileURLWithPath: directory).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = NSSize(width: 1024, height: 1024)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(calibratedRed: 0.075, green: 0.11, blue: 0.15, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 210, yRadius: 210).fill()
        let mint = NSColor(calibratedRed: 0.36, green: 0.89, blue: 0.73, alpha: 1)
        mint.setStroke(); mint.setFill()
        let path = NSBezierPath(); path.lineWidth = 48; path.lineCapStyle = .round
        path.move(to: NSPoint(x: 355, y: 295)); path.line(to: NSPoint(x: 355, y: 728))
        path.move(to: NSPoint(x: 355, y: 450)); path.curve(to: NSPoint(x: 677, y: 710), controlPoint1: NSPoint(x: 640, y: 450), controlPoint2: NSPoint(x: 677, y: 505)); path.stroke()
        for point in [NSPoint(x: 355, y: 290), NSPoint(x: 355, y: 735), NSPoint(x: 677, y: 735)] {
            NSBezierPath(ovalIn: NSRect(x: point.x - 73, y: point.y - 73, width: 146, height: 146)).fill()
            NSColor(calibratedRed: 0.075, green: 0.11, blue: 0.15, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - 29, y: point.y - 29, width: 58, height: 58)).fill(); mint.setFill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", directory + "/AppIcon.icns"]
try process.run(); process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(1) }
try FileManager.default.removeItem(at: iconset)
