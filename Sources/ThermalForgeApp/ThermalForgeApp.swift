//
//  ThermalForgeApp.swift
//  ThermalForge
//
//  Menu bar app for fan control on Apple Silicon Macs: Mac mini, MacBook, MacBook Pro, Mac Studio, iMac.
//

import SwiftUI
import ThermalForgeCore

class AppDelegate: NSObject, NSApplicationDelegate {
    /// Held (handed over by ThermalForgeApp.init) so applicationWillTerminate
    /// can quiesce the fan pipeline — otherwise the exit resetAuto below runs
    /// while the monitor's pipeline still has an in-flight write, which can
    /// land a moment later and re-pin the fans in manual.
    @MainActor var appState: AppState?

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
        // Quiesce FIRST: stop the monitor's ticks, reject new submits, and
        // drain the pump — otherwise an in-flight ramp write can land at the
        // daemon AFTER the resetAuto below and re-pin the fans in manual
        // until the daemon watchdog reverts them.
        MainActor.assumeIsolated {
            appState?.prepareForTermination()
        }

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
    @StateObject private var appState: AppState

    init() {
        let state = AppState()
        _appState = StateObject(wrappedValue: state)
        // The StateObject owns it for SwiftUI; the delegate holds the same
        // instance so the quit path can quiesce the fan pipeline.
        delegate.appState = state
    }

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
