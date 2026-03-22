#!/usr/bin/env swift
//
// Generates ThermalForge app icon from SF Symbol
//

import AppKit

func renderIcon(size: Int, scale: Int = 1) -> NSImage {
    let px = size * scale
    let image = NSImage(size: NSSize(width: px, height: px))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: px, height: px)

    // Background: dark rounded rectangle with gradient
    let cornerRadius = CGFloat(px) * 0.22
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)

    let gradient = NSGradient(colors: [
        NSColor(red: 0.12, green: 0.12, blue: 0.15, alpha: 1.0),
        NSColor(red: 0.08, green: 0.08, blue: 0.11, alpha: 1.0),
    ])!
    gradient.draw(in: path, angle: -90)

    // Fan symbol
    let symbolSize = CGFloat(px) * 0.55
    let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "fan.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config)
    {
        let symbolRect = symbol.size
        let x = (CGFloat(px) - symbolRect.width) / 2
        let y = (CGFloat(px) - symbolRect.height) / 2 + CGFloat(px) * 0.02

        // Orange tint
        NSColor(red: 1.0, green: 0.6, blue: 0.2, alpha: 1.0).set()
        let tinted = NSImage(size: symbolRect)
        tinted.lockFocus()
        symbol.draw(in: NSRect(origin: .zero, size: symbolRect))
        NSColor(red: 1.0, green: 0.6, blue: 0.2, alpha: 1.0).set()
        NSRect(origin: .zero, size: symbolRect).fill(using: .sourceAtop)
        tinted.unlockFocus()

        tinted.draw(in: NSRect(x: x, y: y, width: symbolRect.width, height: symbolRect.height))
    }

    image.unlockFocus()
    return image
}

func savePNG(_ image: NSImage, to path: String) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else { return }
    try! png.write(to: URL(fileURLWithPath: path))
}

// Create iconset directory
let iconsetPath = "ThermalForge.iconset"
try? FileManager.default.removeItem(atPath: iconsetPath)
try! FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

// Generate all required sizes
let sizes = [16, 32, 128, 256, 512]
for size in sizes {
    savePNG(renderIcon(size: size), to: "\(iconsetPath)/icon_\(size)x\(size).png")
    savePNG(renderIcon(size: size, scale: 2), to: "\(iconsetPath)/icon_\(size)x\(size)@2x.png")
}

print("Generated iconset at \(iconsetPath)")
