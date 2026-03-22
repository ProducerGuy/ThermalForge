//
//  ThermalForgeApp.swift
//  ThermalForge
//
//  Menu bar app for fan control on Apple Silicon MacBooks.
//

import SwiftUI
import ThermalForgeCore

@main
struct ThermalForgeApp: App {
    @StateObject private var appState = AppState()

    init() {
        // No Dock icon — menu bar only
        NSApp.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            MenuBarLabel(state: appState.monitorState, maxTemp: appState.maxTemp)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu Bar Label

struct MenuBarLabel: View {
    let state: MonitorState
    let maxTemp: Float?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: iconName)
            if let temp = maxTemp {
                Text("\(Int(temp))°")
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
