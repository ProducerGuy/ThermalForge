//
//  StatusBarController.swift
//  ThermalForge
//
//  Native NSStatusItem + NSPopover. The menu-bar label is drawn with an
//  attributed title so the changing temperature field uses a fixed-pitch font
//  at the system menu-bar size; a proportional font (which MenuBarExtra
//  forces on its label) would make the item width jitter as digits change.
//

import AppKit
import Combine
import SwiftUI
import ThermalForgeCore

// MARK: - Status Bar Controller

@MainActor
final class StatusBarController: NSObject, NSPopoverDelegate {
    private let appState: AppState
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var rendered: RenderedStatusItem?
    private var lastPopoverClose = Date.distantPast

    /// What the status button was last given. Every assignment to a status
    /// item's title or image relayouts the menu bar, and most updates that
    /// reach here carry nothing new on screen.
    private struct RenderedStatusItem: Equatable {
        let symbol: String
        let needsDot: Bool
        let field: String?
    }

    init(appState: AppState) {
        self.appState = appState
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView().environmentObject(appState)
        )

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusBarItemClicked)
        }

        observe()
        updateStatusButton()
    }

    private func observe() {
        Publishers.CombineLatest4(
            appState.$monitorState,
            appState.$maxTemp,
            appState.$useFahrenheit,
            appState.$daemonVersionMismatch
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateStatusButton()
            }
        }
        .store(in: &cancellables)
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        let next = RenderedStatusItem(
            symbol: symbolName,
            needsDot: appState.daemonVersionMismatch != nil,
            field: temperatureField()
        )
        guard next != rendered else { return }
        rendered = next

        button.image = StatusItemRenderer.make(
            symbol: next.symbol,
            needsDot: next.needsDot,
            field: next.field
        )
        button.imagePosition = .imageOnly
        button.attributedTitle = NSAttributedString(string: "")
    }

    /// Three fixed columns; a space holds the hundreds place when there is
    /// no digit for it, so every value renders at the same width.
    private func temperatureField() -> String? {
        guard let tempC = appState.maxTemp else { return nil }
        let display = appState.useFahrenheit ? tempC * 9 / 5 + 32 : tempC
        return String(
            format: "%3d",
            locale: Locale(identifier: "en_US_POSIX"),
            Int(display)
        )
    }

    private var symbolName: String {
        switch appState.monitorState {
        case .safetyOverride: return "exclamationmark.triangle.fill"
        case .active: return "fan.fill"
        case .idle: return "fan"
        }
    }

    @objc private func statusBarItemClicked() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.close()
        } else if Date().timeIntervalSince(lastPopoverClose) > 0.15 {
            // A transient popover dismisses itself on the same click that
            // reaches the button; reopening on that click would leave the
            // item unable to close its own popover.
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        lastPopoverClose = Date()
    }
}

// MARK: - Item Rendering

/// The glyph and the temperature field are composited into one image:
/// the status button's own layout ignores kerning, paragraph indents and
/// attachment placement, and cannot pack the field into the glyph's
/// right side bearing. The three-column field keeps the item width
/// constant; the unbadged composite is a template, so the system tints
/// it exactly like the other menu-bar items.
@MainActor
enum StatusItemRenderer {
    private static let menuFont = NSFont.menuBarFont(ofSize: 0)
    private static let fieldFont = NSFont.monospacedSystemFont(
        ofSize: menuFont.pointSize,
        weight: .regular
    )
    private static let dotDiameter: CGFloat = 5
    // Pulls the field into the glyph's right side bearing, leaving a
    // hair of ink clearance between them.
    private static let glyphFieldGap: CGFloat = -1

    static func make(symbol: String, needsDot: Bool, field: String?) -> NSImage {
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: "ThermalForge")
            ?? NSImage()
        let iconSize = base.size
        let title = title(field: field, needsDot: needsDot)
        let textSize = title.size()
        let canvas = NSSize(
            width: iconSize.width + glyphFieldGap + textSize.width + (needsDot ? 4 : 0),
            height: max(iconSize.height, ceil(textSize.height))
        )
        let image = NSImage(size: canvas, flipped: false) { _ in
            let tint: NSColor = needsDot ? .labelColor : .black
            let glyph = base.withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [tint])
            ) ?? base
            glyph.draw(in: NSRect(
                x: 0,
                y: (canvas.height - iconSize.height) / 2,
                width: iconSize.width,
                height: iconSize.height
            ))
            // Digits sit on cap height centered at the canvas center, so
            // their vertical center matches the glyph's.
            let baseline = canvas.height / 2 - menuFont.capHeight / 2
            title.draw(at: NSPoint(
                x: iconSize.width + glyphFieldGap,
                y: baseline + fieldFont.descender
            ))
            if needsDot {
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: NSRect(
                    x: iconSize.width - dotDiameter + 2,
                    y: canvas.height - dotDiameter,
                    width: dotDiameter,
                    height: dotDiameter
                )).fill()
            }
            return true
        }
        image.accessibilityDescription = field.map { "ThermalForge \($0)°" } ?? "ThermalForge"
        if !needsDot { image.isTemplate = true }
        return image
    }

    private static func title(field: String?, needsDot: Bool) -> NSAttributedString {
        let title = NSMutableAttributedString()
        guard let field else { return title }
        let color: NSColor = needsDot ? .labelColor : .black
        title.append(NSAttributedString(
            string: field,
            attributes: [.font: fieldFont, .foregroundColor: color]
        ))
        title.append(NSAttributedString(
            string: "°",
            attributes: [.font: menuFont, .foregroundColor: color]
        ))
        return title
    }
}
