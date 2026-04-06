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
                TemperatureRow(label: "CPU", value: peakTemp(prefixes: ["TC", "Tp"]), fahrenheit: appState.useFahrenheit)
                TemperatureRow(label: "GPU", value: peakTemp(prefixes: ["TG", "Tg"]), fahrenheit: appState.useFahrenheit)
                TemperatureRow(label: "RAM", value: peakTemp(prefixes: ["TR", "Tm", "TM"]), fahrenheit: appState.useFahrenheit)
                TemperatureRow(label: "SSD", value: peakTemp(prefixes: ["TH"]), fahrenheit: appState.useFahrenheit)
                TemperatureRow(label: "Ambient", value: peakTemp(prefixes: ["TA"]), fahrenheit: appState.useFahrenheit)
            } else {
                Text("Reading sensors...")
                    .foregroundStyle(.secondary)
                    .padding(12)
            }

            Divider().padding(.vertical, 4)

            // Profile picker
            SectionHeader(title: "PROFILE")
            Picker("Profile", selection: Binding(
                get: { appState.activeProfile.id },
                set: { id in
                    if let profile = FanProfile.builtIn.first(where: { $0.id == id }) {
                        appState.selectProfile(profile)
                    }
                }
            )) {
                ForEach(FanProfile.builtIn) { profile in
                    HStack {
                        Text(profile.name)
                        Spacer()
                        if !profile.curve.handsOff {
                            let offC = profile.curve.stopTemp
                            let ceilC = profile.curve.ceilingTemp
                            let offDisp = appState.useFahrenheit ? offC * 9 / 5 + 32 : offC
                            let ceilDisp = appState.useFahrenheit ? ceilC * 9 / 5 + 32 : ceilC
                            let unit = appState.useFahrenheit ? "F" : "C"
                            Text("\(Int(offDisp))→\(Int(ceilDisp))°\(unit)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(profile.id)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .padding(.horizontal, 12)

            Divider().padding(.vertical, 4)

            // Quick actions
            HStack(spacing: 8) {
                Button(action: { appState.setSmart() }) {
                    Label("Smart", systemImage: "fan.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.orange)

                Button(action: { appState.resetAuto() }) {
                    Label("Default", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 12)

            Divider().padding(.vertical, 4)

            // Calibration
            CalibrationView(state: appState.calibrationState)

            Divider().padding(.vertical, 4)

            // Footer
            Toggle("°F / °C", isOn: $appState.useFahrenheit)
                .padding(.horizontal, 12)
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

    private func peakTemp(prefixes: [String]) -> Float? {
        guard let temps = appState.latestStatus?.temperatures else { return nil }
        let values = temps.filter { key, _ in prefixes.contains(where: { key.hasPrefix($0) }) }.values
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
    var fahrenheit: Bool = false

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            if let tempC = value {
                let display = fahrenheit ? tempC * 9 / 5 + 32 : tempC
                let unit = fahrenheit ? "F" : "C"
                Text("\(String(format: "%.1f", display))°\(unit)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(tempColor(tempC))
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 1)
    }

    /// Color thresholds always based on °C
    private func tempColor(_ temp: Float) -> Color {
        if temp >= 90 { return .red }
        if temp >= 75 { return .orange }
        if temp >= 60 { return .yellow }
        return .primary
    }
}
