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
        // Reset fans on quit so daemon doesn't hold stale manual settings
        let client = DaemonClient()
        try? client.execute(.resetAuto)
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
                needsDaemonUpdate: appState.daemonVersionMismatch != nil
            )
        }
        // MenuBarView is a rich custom panel (live telemetry, inline profile
        // picker, banners and bordered controls), so it must use window style.
        // Native menu style can register the status item yet fail to present
        // this view when clicked on newer macOS releases.
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu Bar Label

struct MenuBarLabel: View {
    let state: MonitorState
    let maxTemp: Float?
    var fahrenheit: Bool = false
    var needsDaemonUpdate: Bool = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName)
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
}
