//
//  ThermalForgeApp.swift
//  ThermalForge
//
//  Menu bar app for fan control on Apple Silicon MacBooks.
//

import AppKit
import Combine
import SwiftUI
import ThermalForgeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppState()
    private let menuBarController = MenuBarController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon — menu bar only
        NSApp.setActivationPolicy(.accessory)

        // Prevent duplicate instances
        let bundleID = Bundle.main.bundleIdentifier ?? "com.thermalforge.app"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if running.count > 1 {
            TFLogger.shared.error("Another instance already running — quitting")
            NSApp.terminate(nil)
            return
        }

        menuBarController.configure(with: appState)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Reset fans on quit so the daemon doesn't hold stale APP settings — but
        // ONLY if the app owns the hold. A CLI hold (`sudo thermalforge max`) is the
        // user's deliberate, unsupervised choice; quitting the menu bar app must not
        // destroy it — that's the v0.1.7 arbitration feature. Synchronous on purpose:
        // the process is exiting, so an async write would be dropped; both calls are
        // bounded by the sendRaw timeout.
        let client = DaemonClient()
        if let state = try? client.readState(), state.owner == "app" {
            _ = try? client.execute(.resetAuto)
        }
        // owner == "cli" → leave the CLI hold alone; owner == "none" → nothing to reset.
    }
}

@main
struct ThermalForgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // The menu-bar control itself is owned by MenuBarController. Keeping a
        // Settings scene gives SwiftUI an app scene without creating a window.
        Settings {
            EmptyView()
        }
    }
}

/// Owns the long-lived AppKit status-bar control. SwiftUI's MenuBarExtra label
/// can be recreated when its state changes; retaining one NSStatusBarButton keeps
/// its AX identity stable while its title and accessibility value change normally.
@MainActor
private final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var stateObserver: AnyCancellable?
    private var renderedState: RenderedState?

    func configure(with appState: AppState) {
        guard let button = statusItem.button else {
            TFLogger.shared.error("Could not create menu-bar status button")
            return
        }

        button.target = self
        button.action = #selector(togglePopover(_:))
        button.sendAction(on: [.leftMouseUp])
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)

        // This is deliberately assigned once. Temperature changes are exposed as
        // AXValue, not as a new identity, so menu-bar managers can keep tracking
        // the same control.
        button.setAccessibilityIdentifier("com.thermalforge.menu-bar")
        button.setAccessibilityLabel("ThermalForge")

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView().environmentObject(appState)
        )

        // objectWillChange fires before @Published values are committed. Defer one
        // main-loop turn so rendering sees the completed AppState update.
        stateObserver = appState.objectWillChange.sink { [weak self, weak appState] _ in
            DispatchQueue.main.async {
                guard let self, let appState else { return }
                self.render(appState)
            }
        }
        render(appState)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func render(_ appState: AppState) {
        guard let button = statusItem.button else { return }
        let snapshot = RenderedState(
            monitorState: appState.monitorState,
            temperature: appState.maxTemp.map { temp in
                let displayed = appState.useFahrenheit ? temp * 9 / 5 + 32 : temp
                return Int(displayed)
            },
            fahrenheit: appState.useFahrenheit,
            needsDaemonUpdate: appState.daemonVersionMismatch != nil
        )

        // AppState still publishes dropdown data every monitor cycle. Avoid touching
        // the AppKit status button unless one of its visibly rendered fields changed.
        guard snapshot != renderedState else { return }
        renderedState = snapshot

        button.image = menuBarImage(
            systemName: snapshot.iconName,
            needsDaemonUpdate: snapshot.needsDaemonUpdate
        )
        button.title = snapshot.temperature.map { "\($0)°" } ?? ""
        button.setAccessibilityValue(snapshot.accessibilityValue)
    }

    private func menuBarImage(systemName: String, needsDaemonUpdate: Bool) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else {
            return nil
        }
        guard needsDaemonUpdate else {
            symbol.isTemplate = true
            return symbol
        }

        let image = NSImage(size: NSSize(width: 17, height: 16), flipped: false) { _ in
            symbol.draw(in: NSRect(x: 0, y: 0, width: 14, height: 14))
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: NSRect(x: 12, y: 11, width: 5, height: 5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private struct RenderedState: Equatable {
        let monitorState: MonitorState
        let temperature: Int?
        let fahrenheit: Bool
        let needsDaemonUpdate: Bool

        var iconName: String {
            switch monitorState {
            case .safetyOverride: return "exclamationmark.triangle.fill"
            case .active: return "fan.fill"
            case .idle: return "fan"
            }
        }

        var accessibilityValue: String {
            guard let temperature else { return "Temperature unavailable" }
            return "\(temperature) degrees \(fahrenheit ? "Fahrenheit" : "Celsius")"
        }
    }
}
