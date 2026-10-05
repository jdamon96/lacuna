#!/usr/bin/swift
import AppKit

// The icon is entirely vector-drawn here, so every exported size stays crisp.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: generate-icon.swift output.iconset\n", stderr)
    exit(1)
}

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func drawIcon(pixels: Int, filename: String) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "LacunaIcon", code: 1)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let scale = CGFloat(pixels) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)

    let silhouette = NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904), xRadius: 208, yRadius: 208)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.20)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor(calibratedRed: 0.12, green: 0.11, blue: 0.20, alpha: 1).setFill()
    silhouette.fill()
    NSGraphicsContext.restoreGraphicsState()

    let gradient = NSGradient(starting: NSColor(calibratedRed: 0.24, green: 0.21, blue: 0.36, alpha: 1),
                              ending: NSColor(calibratedRed: 0.12, green: 0.11, blue: 0.20, alpha: 1))!
    gradient.draw(in: silhouette, angle: -90)
    NSColor.white.withAlphaComponent(0.08).setStroke()
    silhouette.lineWidth = 2
    silhouette.stroke()

    // A matched pair of braces, with generous space for what comes next.
    let leftBrace = NSBezierPath()
    leftBrace.move(to: NSPoint(x: 405, y: 748))
    leftBrace.curve(to: NSPoint(x: 315, y: 658), controlPoint1: NSPoint(x: 333, y: 748), controlPoint2: NSPoint(x: 315, y: 726))
    leftBrace.line(to: NSPoint(x: 315, y: 599))
    leftBrace.curve(to: NSPoint(x: 256, y: 512), controlPoint1: NSPoint(x: 315, y: 546), controlPoint2: NSPoint(x: 299, y: 523))
    leftBrace.curve(to: NSPoint(x: 315, y: 425), controlPoint1: NSPoint(x: 299, y: 501), controlPoint2: NSPoint(x: 315, y: 478))
    leftBrace.line(to: NSPoint(x: 315, y: 366))
    leftBrace.curve(to: NSPoint(x: 405, y: 276), controlPoint1: NSPoint(x: 315, y: 298), controlPoint2: NSPoint(x: 333, y: 276))
    leftBrace.lineWidth = 50
    leftBrace.lineCapStyle = .round
    leftBrace.lineJoinStyle = .round
    NSColor(calibratedRed: 0.92, green: 0.88, blue: 0.99, alpha: 1).setStroke()
    leftBrace.stroke()

    let rightBrace = leftBrace.copy() as! NSBezierPath
    var reflection = AffineTransform()
    reflection.translate(x: 1024, y: 0)
    reflection.scale(x: -1, y: 1)
    rightBrace.transform(using: reflection)
    rightBrace.stroke()

    let insertion = NSBezierPath(roundedRect: NSRect(x: 488, y: 450, width: 48, height: 124), xRadius: 24, yRadius: 24)
    NSColor(calibratedRed: 0.70, green: 0.60, blue: 0.98, alpha: 1).setFill()
    insertion.fill()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "LacunaIcon", code: 2)
    }
    try png.write(to: destination.appendingPathComponent(filename))
}

for size in [16, 32, 128, 256, 512] {
    try drawIcon(pixels: size, filename: "icon_\(size)x\(size).png")
    try drawIcon(pixels: size * 2, filename: "icon_\(size)x\(size)@2x.png")
}
