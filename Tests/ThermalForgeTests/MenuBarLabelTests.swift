import AppKit
import SwiftUI
import Testing
@testable import ThermalForgeApp
import ThermalForgeCore

@Suite("Menu bar label — minimum image width, no hardware", .serialized)
@MainActor
struct MenuBarLabelTests {
    private func bitmap(_ image: NSImage, scale: Int) throws -> NSBitmapImageRep {
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(image.size.width) * scale,
            pixelsHigh: Int(image.size.height) * scale, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = image.size
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: image.size))
        context.flushGraphics()
        return bitmap
    }

    @Test("One/two-digit readings, symbols and missing data occupy the minimum canvas")
    func minimumCanvas() throws {
        var sizes = Set<String>()
        for symbol in ["fan", "fan.fill", "exclamationmark.triangle.fill"] {
            for text: String? in [nil, "9°", "10°", "49°", "50°", "99°"] {
                for warning in [false, true] {
                    let image = MenuBarLabelImage.make(symbol: symbol, text: text,
                                                       needsWarning: warning, colorScheme: .light)
                    sizes.insert(NSStringFromSize(image.size))
                    #expect(image.isTemplate == !warning)
                    for scale in [1, 2] {
                        let pixels = try bitmap(image, scale: scale)
                        #expect(pixels.pixelsWide == Int(image.size.width) * scale)
                        #expect(pixels.pixelsHigh == Int(image.size.height) * scale)
                        // Ink must exist, and the rightmost field must not be clipped.
                        var ink = 0
                        for y in 0..<pixels.pixelsHigh {
                            for x in 0..<pixels.pixelsWide {
                                if (pixels.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { ink += 1 }
                            }
                            #expect((pixels.colorAt(x: pixels.pixelsWide - 1, y: y)?.alphaComponent ?? 0) < 0.1)
                        }
                        #expect(ink > 20)
                    }
                }
            }
        }
        #expect(sizes.count == 1)
    }

    @Test("The complete icon and reading stay centered within the reserved or expanded canvas")
    func centeredGroup() throws {
        for scale in [1, 2] {
            for text: String? in [nil, "9°", "10°", "49°", "50°", "99°", "100°", "212°", "301°", "999°"] {
                let pixels = try bitmap(MenuBarLabelImage.make(
                    symbol: "fan", text: text, needsWarning: false, colorScheme: .light
                ), scale: scale)
                var left = pixels.pixelsWide
                var right = 0
                for x in 0..<pixels.pixelsWide {
                    for y in 0..<pixels.pixelsHigh {
                        if (pixels.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
                            left = min(left, x)
                            right = max(right, x)
                        }
                    }
                }
                // Glyph side bearings and antialiasing can differ by a pixel.
                #expect(abs(left - (pixels.pixelsWide - 1 - right)) <= 2 * scale)
            }
        }
    }

    @Test("Warning remains orange in both appearances and text changes contrast")
    func warningColors() throws {
        for scheme in [ColorScheme.light, .dark] {
            let pixels = try bitmap(MenuBarLabelImage.make(
                symbol: "fan.fill", text: "100°", needsWarning: true, colorScheme: scheme
            ), scale: 2)
            var orange = 0
            var foreground = 0
            for y in 0..<pixels.pixelsHigh {
                for x in 0..<pixels.pixelsWide {
                    guard let c = pixels.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          c.alphaComponent > 0.8 else { continue }
                    if c.redComponent > 0.8 && c.greenComponent > 0.2 && c.greenComponent < 0.8 && c.blueComponent < 0.2 {
                        orange += 1
                    }
                    if x > pixels.pixelsWide / 2 {
                        if scheme == .light && c.redComponent < 0.1 { foreground += 1 }
                        if scheme == .dark && c.redComponent > 0.9 { foreground += 1 }
                    }
                }
            }
            #expect(orange > 10)
            #expect(foreground > 10)
        }
    }

    @Test("Three-digit readings expand beyond the minimum without shrinking or truncating text")
    func threeDigitReadings() throws {
        let normal = MenuBarLabelImage.make(symbol: "fan", text: "99°", needsWarning: false, colorScheme: .light)
        for value: Float in [100, 212, 999] {
            let text = try #require(MenuBarLabel(state: .idle, maxTemp: value).temperatureText)
            #expect(text == "\(Int(value))°")
            let image = MenuBarLabelImage.make(symbol: "fan", text: text, needsWarning: false, colorScheme: .light)
            #expect(image.size.width > normal.size.width)
            #expect(image.size.height == normal.size.height)
            let pixels = try bitmap(image, scale: 2)
            // The degree symbol must still be drawn at the far end of the field.
            var degreeInk = 0
            for x in (pixels.pixelsWide - 10)..<pixels.pixelsWide {
                for y in 0..<(pixels.pixelsHigh / 2) {
                    if (pixels.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { degreeInk += 1 }
                }
            }
            #expect(degreeInk > 2)
        }
    }

    @Test("Display retains truncation, Celsius/Fahrenheit conversion and unavailable input")
    func readings() {
        for (celsius, fahrenheit, expected) in [(Float(49.9), false, "49°"), (50, false, "50°"),
                                                (100, false, "100°"), (100, true, "212°"), (149.9, true, "301°")] {
            #expect(MenuBarLabel(state: .idle, maxTemp: celsius, fahrenheit: fahrenheit).temperatureText == expected)
        }
        for value: Float? in [nil, .nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
            #expect(MenuBarLabel(state: .idle, maxTemp: value).temperatureText == nil)
        }
    }
}
