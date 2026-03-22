//
//  MenuBarView.swift
//  ThermalForge
//
//  Menu bar dropdown content.
//

import SwiftUI
import ThermalForgeCore

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("ThermalForge")
                    .font(.headline)
                Spacer()
                stateIndicator
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            // Fan speeds
            if let status = appState.latestStatus {
                SectionHeader(title: "FANS")
                ForEach(status.fans, id: \.index) { fan in
                    HStack {
                        Text("Fan \(fan.index)")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(fan.actualRPM) RPM")
                            .font(.system(.body, design: .monospaced))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 1)
                }

                Divider().padding(.vertical, 4)

                // Temperatures
                SectionHeader(title: "TEMPERATURES")
                TemperatureRow(label: "CPU", value: peakTemp(["cpu_die_max", "cpu_hotpoint"]))
                TemperatureRow(label: "GPU", value: peakTemp(["gpu_1", "gpu_2", "gpu_3"]))
                TemperatureRow(label: "RAM", value: peakTemp(["ram_die_max"]))
                TemperatureRow(label: "SSD", value: peakTemp(["ssd_max"]))
                TemperatureRow(label: "Ambient", value: peakTemp(["ambient"]))
            } else {
                Text("Reading sensors...")
                    .foregroundStyle(.secondary)
                    .padding(12)
            }

            Divider().padding(.vertical, 4)

            // Profile picker
            SectionHeader(title: "PROFILE")
            ForEach(FanProfile.builtIn) { profile in
                ProfileButton(
                    profile: profile,
                    isActive: appState.activeProfile.id == profile.id
                ) {
                    appState.selectProfile(profile)
                }
            }

            Divider().padding(.vertical, 4)

            // Quick actions
            HStack(spacing: 8) {
                Button(action: { appState.setMax() }) {
                    Label("Max", systemImage: "fan.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.orange)

                Button(action: { appState.resetAuto() }) {
                    Label("Auto", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 12)

            Divider().padding(.vertical, 4)

            // Footer
            Toggle("Launch at Login", isOn: $appState.launchAtLogin)
                .padding(.horizontal, 12)

            Button(action: { NSApp.terminate(nil) }) {
                Text("Quit ThermalForge")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 10)
        }
        .frame(width: 260)
    }

    // MARK: - Helpers

    @ViewBuilder
    private var stateIndicator: some View {
        switch appState.monitorState {
        case .safetyOverride:
            Label("SAFETY", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        case .active(let name):
            Label(name, systemImage: "fan.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .idle:
            Label("Idle", systemImage: "fan")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func peakTemp(_ keys: [String]) -> Float? {
        guard let temps = appState.latestStatus?.temperatures else { return nil }
        let values = keys.compactMap { temps[$0] }
        return values.max()
    }
}

// MARK: - Subviews

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.bottom, 2)
    }
}

private struct TemperatureRow: View {
    let label: String
    let value: Float?

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            if let temp = value {
                Text("\(String(format: "%.1f", temp))°C")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(tempColor(temp))
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
    }

    private func tempColor(_ temp: Float) -> Color {
        if temp >= 90 { return .red }
        if temp >= 75 { return .orange }
        if temp >= 60 { return .yellow }
        return .primary
    }
}

private struct ProfileButton: View {
    let profile: FanProfile
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isActive ? .blue : .secondary)
                Text(profile.name)
                Spacer()
                if let cpu = profile.triggers.cpuTemp {
                    Text("CPU>\(Int(cpu))°")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }
}
