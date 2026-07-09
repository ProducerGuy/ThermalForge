//
//  ThermalForgeApp.swift
//  ThermalForge
//

import SwiftUI
import ThermalForgeCore

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let bundleID = Bundle.main.bundleIdentifier ?? "com.thermalforge.app"
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        if running.count > 1 {
            TFLogger.shared.error("Another instance already running — quitting")
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
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
                thermalPressure: appState.thermalPressure,
                maxTemp: appState.maxTemp,
                fahrenheit: appState.useFahrenheit,
                cyclingEnabled: appState.menuBarCyclingEnabled,
                cycleLabel: appState.menuBarLabel
            )
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu Bar Label

struct MenuBarLabel: View {
    let state: MonitorState
    let thermalPressure: ThermalPressure
    let maxTemp: Float?
    var fahrenheit: Bool = false
    var cyclingEnabled: Bool = false
    var cycleLabel: String = ""

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
            if cyclingEnabled && !cycleLabel.isEmpty {
                Text(cycleLabel)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(iconColor)
            } else if let tempC = maxTemp {
                let display = fahrenheit ? tempC * 9 / 5 + 32 : tempC
                Text("\(Int(display))°")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(iconColor)
            }
        }
    }

    private var iconName: String {
        switch state {
        case .safetyOverride:         return "exclamationmark.triangle.fill"
        case .coolDown:               return "thermometer.medium"
        case .active:                 return "fan.fill"
        case .idle:                   return "fan"
        }
    }

    private var iconColor: Color {
        switch state {
        case .safetyOverride: return .red
        case .coolDown:       return .orange
        case .active, .idle:
            switch thermalPressure {
            case .critical: return .red
            case .serious:  return .orange
            case .fair:     return .yellow
            case .nominal:  return .primary
            }
        }
    }
}
