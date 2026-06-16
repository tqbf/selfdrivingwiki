#!/usr/bin/env swift
//
// make-icon.swift — render the Self Driving Wiki app icon at every macOS icon size into
// build/AppIcon.iconset, which the Makefile then packs with `iconutil`.
//
// The icon: a rounded-rect "squircle" with a blue→indigo gradient and a white
// SF Symbol (books.vertical.fill) centered on it. No external assets — the
// glyph is system-provided, so the icon regenerates anywhere the toolchain
// runs. Re-run automatically when this script changes (see the Makefile rule).
//
import AppKit

let symbolName = "books.vertical.fill"
let outDir = "build/AppIcon.iconset"

// (filename, pixel dimension). Standard macOS iconset manifest.
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func renderIcon(pixels: Int) -> NSBitmapImageRep {
    let size = CGFloat(pixels)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { fatalError("could not allocate \(pixels)px bitmap") }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Rounded-rect background with a vertical gradient. Inset slightly so the
    // squircle doesn't touch the pixel edges (matches macOS icon grid).
    let inset = size * 0.06
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let corner = (size - 2 * inset) * 0.22
    let path = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
    let gradient = NSGradient(
        colors: [
            NSColor(srgbRed: 0.20, green: 0.48, blue: 0.96, alpha: 1),
            NSColor(srgbRed: 0.36, green: 0.30, blue: 0.86, alpha: 1),
        ]
    )
    gradient?.draw(in: path, angle: -90)

    // White SF Symbol, centered, sized to ~58% of the canvas.
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.52, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        symbol.draw(at: .zero, from: NSRect(origin: .zero, size: symbol.size), operation: .sourceOver, fraction: 1)
        NSColor.white.set()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceAtop)
        tinted.unlockFocus()

        let glyphRect = NSRect(
            x: (size - tinted.size.width) / 2,
            y: (size - tinted.size.height) / 2,
            width: tinted.size.width,
            height: tinted.size.height
        )
        tinted.draw(in: glyphRect, from: NSRect(origin: .zero, size: tinted.size), operation: .sourceOver, fraction: 1)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
try? fm.removeItem(atPath: outDir)
try! fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

for (name, pixels) in variants {
    let rep = renderIcon(pixels: pixels)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encode failed for \(name)")
    }
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}

print("✓ wrote \(variants.count) icons to \(outDir)")
