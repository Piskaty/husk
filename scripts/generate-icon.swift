#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments
let outputIcnsPath = args.count > 1 ? args[1] : "/tmp/AppIcon.icns"

func renderIcon(pixelSize: Int) -> Data? {
    let size = CGFloat(pixelSize)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else {
        NSGraphicsContext.restoreGraphicsState()
        return nil
    }

    let inset = size * 0.08
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let cornerRadius = rect.width * 0.225
    let squircle = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // 1. Deep Obsidian / Liquid Glass Base Gradient
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bgColors = [
        CGColor(red: 0.14, green: 0.15, blue: 0.17, alpha: 1.0),
        CGColor(red: 0.07, green: 0.075, blue: 0.085, alpha: 1.0)
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.midX, y: rect.maxY),
            end: CGPoint(x: rect.midX, y: rect.minY),
            options: []
        )
    }

    // Subtle top specular glow
    let glowColors = [
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.14),
        CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.0)
    ] as CFArray
    if let glow = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(
            glow,
            startCenter: CGPoint(x: rect.midX, y: rect.maxY),
            startRadius: 0,
            endCenter: CGPoint(x: rect.midX, y: rect.maxY),
            endRadius: rect.width * 0.75,
            options: []
        )
    }
    ctx.restoreGState()

    // 2. Outer Liquid Glass Specular Rim
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.setStrokeColor(CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.22))
    ctx.setLineWidth(max(1.0, size * 0.015))
    ctx.strokePath()
    ctx.restoreGState()

    // 3. Minimalist Geometric "Husk + Seed" Mark
    let center = CGPoint(x: size * 0.5, y: size * 0.5)
    let outerRadius = rect.width * 0.27
    let ringWidth = max(2.0, size * 0.055)

    ctx.saveGState()
    ctx.setStrokeColor(CGColor(red: 0.94, green: 0.95, blue: 0.97, alpha: 0.88))
    ctx.setLineWidth(ringWidth)
    ctx.setLineCap(.round)

    // Left husk arc
    ctx.addArc(
        center: CGPoint(x: center.x - size * 0.015, y: center.y),
        radius: outerRadius,
        startAngle: .pi * 0.62,
        endAngle: .pi * 1.38,
        clockwise: false
    )
    ctx.strokePath()

    // Right husk arc
    ctx.addArc(
        center: CGPoint(x: center.x + size * 0.015, y: center.y),
        radius: outerRadius,
        startAngle: -.pi * 0.38,
        endAngle: .pi * 0.38,
        clockwise: false
    )
    ctx.strokePath()

    // Inner untouched seed
    let seedRadius = rect.width * 0.088
    let seedRect = CGRect(
        x: center.x - seedRadius,
        y: center.y - seedRadius,
        width: seedRadius * 2,
        height: seedRadius * 2
    )
    ctx.setFillColor(CGColor(red: 0.22, green: 0.84, blue: 0.52, alpha: 1.0))
    ctx.fillEllipse(in: seedRect)
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

func appendUInt32BE(_ value: UInt32, to data: inout Data) {
    var big = value.bigEndian
    withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
}

let chunks: [(osType: String, pixels: Int)] = [
    ("icp4", 16),
    ("icp5", 32),
    ("icp6", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic09", 512),
    ("ic10", 1024)
]

var bodyData = Data()
for chunk in chunks {
    guard let png = renderIcon(pixelSize: chunk.pixels) else { continue }
    bodyData.append(contentsOf: chunk.osType.utf8)
    appendUInt32BE(UInt32(8 + png.count), to: &bodyData)
    bodyData.append(png)
}

var icnsData = Data()
icnsData.append(contentsOf: "icns".utf8)
appendUInt32BE(UInt32(8 + bodyData.count), to: &icnsData)
icnsData.append(bodyData)

let outURL = URL(fileURLWithPath: outputIcnsPath)
try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
try icnsData.write(to: outURL, options: .atomic)

if args.count > 2, let png256 = renderIcon(pixelSize: 256) {
    let pngURL = URL(fileURLWithPath: args[2])
    try FileManager.default.createDirectory(at: pngURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try png256.write(to: pngURL, options: .atomic)
}
