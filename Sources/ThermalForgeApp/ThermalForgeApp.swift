//
//  ThermalForgeApp.swift
//  ThermalForge
//
//  Menu bar app for fan control on Apple Silicon MacBooks.
//

import SwiftUI
import ThermalForgeCore

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon — menu bar only
        NSApp.setActivationPolicy(.accessory)

        // Prevent duplicate instances
        let bundleID = Bundle.main.bundleIdentifier ?? "com.thermalforge.app"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if running.count > 1 {
            TFLogger.shared.error("Another instance already running — quitting")
            NSApp.terminate(nil)
        }
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
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            MenuBarLabel(
                state: appState.monitorState,
                maxTemp: appState.maxTemp,
                fahrenheit: appState.useFahrenheit,
                needsDaemonUpdate: appState.daemonVersionMismatch != nil,
                speedColor: appState.fanSpeedColor
            )
        }
        .menuBarExtraStyle(.window)

        // Custom Profile editor — a real window (not the menu bar popover) since
        // it's a form, not a quick action. Opened via `openWindow(id: "profile-editor")`
        // after setting `appState.profileEditorTarget`.
        Window("Custom Profile", id: "profile-editor") {
            ProfileEditorWindow()
                .environmentObject(appState)
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - Menu Bar Label

struct MenuBarLabel: View {
    let state: MonitorState
    let maxTemp: Float?
    var fahrenheit: Bool = false
    var needsDaemonUpdate: Bool = false
    /// A Custom Profile curve point's color, once the fan's actual speed reaches it
    /// (rq.md-adjacent feature — see `AppState.fanSpeedColor`). nil keeps the icon's
    /// default template appearance (no `.foregroundStyle` applied at all), so this
    /// can never regress how every existing profile's icon already looks.
    var speedColor: Color?

    var body: some View {
        HStack(spacing: 3) {
            icon
                .overlay(alignment: .topTrailing) {
                    // Small dot when the daemon is out of sync — visible without
                    // opening the menu, for users who never touch the CLI.
                    if needsDaemonUpdate {
                        Circle()
                            .fill(.orange)
                            .frame(width: 5, height: 5)
                            .offset(x: 3, y: -2)
                    }
                }
            if let tempC = maxTemp {
                let display = fahrenheit ? tempC * 9 / 5 + 32 : tempC
                Text("\(Int(display))°")
                    .font(.system(.caption, design: .monospaced))
            }
        }
    }

    private var iconName: String {
        switch state {
        case .safetyOverride: return "exclamationmark.triangle.fill"
        case .active: return "fan.fill"
        case .idle: return "fan"
        }
    }

    @ViewBuilder
    private var icon: some View {
        if let speedColor {
            Image(systemName: iconName).foregroundStyle(speedColor)
        } else {
            Image(systemName: iconName)
        }
    }
}
