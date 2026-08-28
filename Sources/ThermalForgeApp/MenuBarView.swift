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

            if appState.daemonUnreachable {
                // Daemon not answering — nothing in the app can touch the fans, so
                // this takes over the top of the menu and offers a one-click fix.
                // The version/hold banners are moot while it's unreachable.
                DaemonDownBanner(onRestart: { appState.restartDaemon() })
                Divider()
            } else {
                // Update-needed banner — shown whenever the daemon is out of sync.
                // Persistent (no dismiss): a stale daemon should keep nagging.
                if let daemonVersion = appState.daemonVersionMismatch {
                    DaemonUpdateBanner(daemonVersion: daemonVersion)
                    Divider()
                }

                // CLI-hold banner — the app is reflecting a hold set from the
                // terminal and won't adjust fans until the user takes over. The
                // Default button (or picking a profile) releases it.
                if let hold = appState.externalHold {
                    ExternalHoldBanner(hold: hold)
                    Divider()
                }

                // Update-available banner — informational, lowest priority. Suppressed
                // while "Update needed" (daemon out of sync) shows, so two update-ish
                // banners never stack; can coexist with a CLI hold.
                if appState.daemonVersionMismatch == nil, let update = appState.availableUpdate {
                    UpdateAvailableBanner(update: update, onDismiss: { appState.dismissUpdate() })
                    Divider()
                }
            }

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
                            let unit = appState.useFahrenheit ? "F" : "C"
                            if profile.curve.instantEngage {
                                // Max: show instant trigger temp
                                let startC = profile.curve.startTemp
                                let startDisp = appState.useFahrenheit ? startC * 9 / 5 + 32 : startC
                                Text("\(Int(startDisp))°\(unit) instant")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                let startC = profile.curve.startTemp
                                let ceilC = profile.curve.ceilingTemp
                                let startDisp = appState.useFahrenheit ? startC * 9 / 5 + 32 : startC
                                let ceilDisp = appState.useFahrenheit ? ceilC * 9 / 5 + 32 : ceilC
                                Text("\(Int(startDisp))→\(Int(ceilDisp))°\(unit)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
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
                // Toggle-as-button holds the system fill while Smart is the active
                // profile — Apple draws it, it honors .tint, and it adapts to light/dark.
                Toggle(isOn: Binding(
                    get: { appState.activeProfile.id == "smart" },
                    set: { isOn in
                        if isOn {
                            appState.setSmart()
                        } else {
                            // Turning Smart off returns fans to Apple's default (Silent),
                            // same as the Default button. Required so the toggle can turn
                            // off at all — otherwise `get` stays true and snaps it back on.
                            appState.resetAuto()
                        }
                    }
                )) {
                    Label("Smart", systemImage: "fan.fill")
                        .frame(maxWidth: .infinity)
                }
                .toggleStyle(.button)
                .tint(.orange)

                Button(action: { appState.resetAuto() }) {
                    Label("Default", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, 12)

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

/// Banner shown when a hold was set from the CLI. Explains what's pinned and how
/// to release it without needing to know any terminal commands.
private struct ExternalHoldBanner: View {
    let hold: DaemonHoldState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Fans held from Terminal", systemImage: "terminal.fill")
                .font(.caption.bold())
                .foregroundStyle(.orange)

            Text(describe(hold.command))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Press Default below (or pick a profile) to release.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }

    private func describe(_ command: String?) -> String {
        let parts = (command ?? "").split(separator: " ").map(String.init)
        switch parts.first {
        // Approximate language on purpose: the held value is the fan's TARGET, but the
        // RPM shown in the fan rows is the actual tach, which hovers ~1% around it. Exact
        // wording ("pinned to 3500") next to a row reading 3488/3512 looks like a bug.
        case "max":
            return "Fans are held at maximum. The app won't adjust them until you take over."
        case "set" where parts.count > 1:
            return "Fans are held at about \(parts[1]) RPM. The app won't adjust them until you take over."
        case "setfan" where parts.count > 2:
            return "Fan \(parts[1]) is held at about \(parts[2]) RPM. The app won't adjust fans until you take over."
        default:
            return "Fans are held manually. The app won't adjust them until you take over."
        }
    }
}

/// Non-modal in-menu banner telling the user the background daemon is out of
/// sync and exactly how to fix it. Command is selectable so it can be copied.
private struct DaemonUpdateBanner: View {
    let daemonVersion: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Update needed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.bold())
                .foregroundStyle(.orange)

            Text("The background service is running \(daemonVersion), but the app is \(ThermalForgeVersion.current). Fan control may not match what you set until they're re-synced.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Run this in Terminal:")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
                .fixedSize(horizontal: false, vertical: true)

            Text("sudo thermalforge install")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
    }
}

/// Shown when a newer ThermalForge release exists than the installed build. Purely
/// informational (blue, not the orange "Update needed"): it tells the user an update
/// shipped and how to get it — the app can't run `brew upgrade` for them. Dismissible
/// per-version via "Later".
private struct UpdateAvailableBanner: View {
    let update: AvailableUpdate
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Update available", systemImage: "arrow.down.circle.fill")
                .font(.caption.bold())
                .foregroundStyle(.blue)

            Text("ThermalForge \(update.version) is available. You have \(ThermalForgeVersion.current).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Update with:")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
                .fixedSize(horizontal: false, vertical: true)

            Text("brew upgrade thermalforge && sudo thermalforge install")
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))

            Text("Built from source? Run  git pull && ./setup.sh")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if let url = URL(string: update.url) {
                    Link("What's new", destination: url)
                        .font(.caption2)
                }
                Spacer()
                Button("Later", action: onDismiss)
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.12))
    }
}

/// Shown when the daemon has stopped answering — fan control is impossible until
/// it's back. Offers a one-click restart (launchd kickstart via a macOS admin
/// prompt). The daemon's KeepAlive usually restarts it on its own, so this is the
/// manual nudge for the rare stuck case; it never asks the user to reinstall.
private struct DaemonDownBanner: View {
    let onRestart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Fan control unavailable", systemImage: "exclamationmark.octagon.fill")
                .font(.caption.bold())
                .foregroundStyle(.red)

            Text("The background service isn't responding, so profiles and Default can't change the fans right now.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onRestart) {
                Label("Restart daemon", systemImage: "arrow.clockwise")
                    .font(.caption.bold())
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .padding(.top, 2)

            Text("Asks for your password once. If it doesn't come back right away, it will keep retrying on its own.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.12))
    }
}

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
