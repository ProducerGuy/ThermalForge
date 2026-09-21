import AppKit
import SwiftUI
import ThermalForgeCore

struct MenuBarLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    let state: MonitorState
    let maxTemp: Float?
    var fahrenheit: Bool = false
    var needsDaemonUpdate: Bool = false

    var body: some View {
        Image(nsImage: MenuBarLabelImage.make(
            symbol: iconName, text: temperatureText,
            needsWarning: needsDaemonUpdate, colorScheme: colorScheme
        ))
        .help("ThermalForge: \(accessibleReading)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("ThermalForge")
        .accessibilityValue(accessibleReading)
    }

    var temperatureText: String? {
        guard let tempC = maxTemp else { return nil }
        let display = fahrenheit ? tempC * 9 / 5 + 32 : tempC
        guard display.isFinite, let integer = Int(exactly: Double(display.rounded(.towardZero))) else { return nil }
        return "\(integer)°"
    }

    private var accessibleReading: String {
        guard let temperatureText else { return "Temperature unavailable" }
        return temperatureText + (fahrenheit ? "F" : "C")
    }

    private var iconName: String {
        switch state {
        case .safetyOverride: return "exclamationmark.triangle.fill"
        case .active: return "fan.fill"
        case .idle: return "fan"
        }
    }
}

/// A minimum logical image size survives MenuBarExtra's native label measurement.
/// AppKit renders the drawing handler at the destination screen's backing scale.
@MainActor
enum MenuBarLabelImage {
    private static let font = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular
    )
    private static let symbols = ["fan", "fan.fill", "exclamationmark.triangle.fill"]
        .compactMap { name -> (String, NSImage)? in
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular))
            else { return nil }
            return (name, image)
        }
    private static let iconWidth = ceil(symbols.map { $0.1.size.width }.max() ?? font.pointSize)
    private static let iconHeight = ceil(symbols.map { $0.1.size.height }.max() ?? font.pointSize)
    private static let fieldSize = ("88°" as NSString).size(withAttributes: [.font: font])
    private static let gap: CGFloat = 3
    static let minimumSize = NSSize(width: iconWidth + gap + ceil(fieldSize.width),
                                    height: max(20, iconHeight, ceil(fieldSize.height)))

    static func make(symbol: String, text: String?, needsWarning: Bool, colorScheme: ColorScheme) -> NSImage {
        let glyph = symbols.first { $0.0 == symbol }?.1
        // Normal labels are templates for native contrast/selection. The warning
        // composite keeps its orange badge and redraws when colorScheme changes.
        let color: NSColor = needsWarning && colorScheme == .dark ? .white : .black
        let title = text.map { NSAttributedString(string: $0, attributes: [.font: font, .foregroundColor: color]) }
        let glyphWidth = glyph?.size.width ?? iconWidth
        let contentWidth = glyphWidth + (title.map { gap + $0.size().width } ?? (needsWarning ? gap : 0))
        // Reserve two digits for normal readings; longer content can grow.
        // Center the complete icon + reading while retaining the same inner gap.
        let size = NSSize(width: max(minimumSize.width, ceil(contentWidth)), height: minimumSize.height)
        let contentX = (size.width - contentWidth) / 2
        let image = NSImage(size: size, flipped: false) { _ in
            if let glyph {
                let rect = NSRect(x: contentX,
                                  y: (size.height - glyph.size.height) / 2,
                                  width: glyph.size.width, height: glyph.size.height)
                glyph.draw(in: rect)
                color.setFill()
                rect.fill(using: .sourceAtop)
            }
            if let title {
                title.draw(at: NSPoint(x: contentX + glyphWidth + gap, y: (size.height - title.size().height) / 2))
            }
            if needsWarning {
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: NSRect(x: contentX + glyphWidth - 2, y: size.height - 5, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = !needsWarning
        return image
    }
}
