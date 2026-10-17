// Draws the app icon and writes Resources/AppIcon.icns.
// Run from the repo root: swift scripts/make-icon.swift
// A graphite tile with one lens ring: the eye in the name, nothing else.

import AppKit

let canvas: CGFloat = 1024
// Apple's icon grid: an 824 pt tile centred on the 1024 pt canvas, corner radius 185.4 pt.
let tileSize: CGFloat = 824
let cornerRadius: CGFloat = 185.4
// The sizes iconutil expects; each is also drawn at @2x.
let sizes = [16, 32, 128, 256, 512]

func drawIcon(pixels: Int) -> NSBitmapImageRep {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)

    let inset = (canvas - tileSize) / 2
    let tile = CGRect(x: inset, y: inset, width: tileSize, height: tileSize)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Soft drop shadow under the tile, as system icons have.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    context.addPath(tilePath)
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let graphite = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [NSColor(white: 0.20, alpha: 1).cgColor, NSColor(white: 0.07, alpha: 1).cgColor] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(graphite, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    context.restoreGState()

    let center = CGPoint(x: canvas / 2, y: canvas / 2)
    let ringRadius: CGFloat = 214
    context.setStrokeColor(NSColor(white: 0.96, alpha: 1).cgColor)
    context.setLineWidth(30)
    context.strokeEllipse(in: CGRect(x: center.x - ringRadius, y: center.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2))

    let pupilRadius: CGFloat = 58
    context.setFillColor(NSColor(white: 0.96, alpha: 1).cgColor)
    context.fillEllipse(in: CGRect(x: center.x - pupilRadius, y: center.y - pupilRadius, width: pupilRadius * 2, height: pupilRadius * 2))

    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for size in sizes {
    try drawIcon(pixels: size).representation(using: .png, properties: [:])!
        .write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try drawIcon(pixels: size * 2).representation(using: .png, properties: [:])!
        .write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
