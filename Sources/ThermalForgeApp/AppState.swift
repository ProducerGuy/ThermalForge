//
//  AppState.swift
//  ThermalForge
//
//  Observable bridge between ThermalMonitor and SwiftUI.
//

import ServiceManagement
import SwiftUI
@preconcurrency import ThermalForgeCore

@MainActor
final class AppState: ObservableObject {
    @Published var latestStatus: ThermalStatus?
    @Published var activeProfile: FanProfile = .silent
    @Published var monitorState: MonitorState = .idle
    @Published var maxTemp: Float?
    @Published var useFahrenheit: Bool = UserDefaults.standard.bool(forKey: "useFahrenheit") {
        didSet { UserDefaults.standard.set(useFahrenheit, forKey: "useFahrenheit") }
    }
    /// Extra Cool: a sticky modifier that shifts the active profile colder and
    /// louder. The toggle is persisted; the *selected profile* deliberately is
    /// not — the app always starts in Silent (hands-off) on launch for safety,
    /// so a restored `true` here simply takes effect the moment a profile is
    /// chosen.
    @Published var extraCool: Bool = UserDefaults.standard.bool(forKey: "extraCool") {
        didSet {
            UserDefaults.standard.set(extraCool, forKey: "extraCool")
            applyProfile(baseProfile)
            TFLogger.shared.profile("Extra Cool \(extraCool ? "ON" : "off")")
        }
    }
    @Published var launchAtLogin: Bool = false {
        didSet { updateLoginItem() }
    }

    private var monitor: ThermalMonitor?
    private let executor = PrivilegedExecutor()
    private var heartbeatTimer: Timer?
    /// The profile the user picked, before any Extra Cool transform.
    private var baseProfile: FanProfile = .silent

    init() {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)

        // Clean state: reset fans to auto on every launch.
        try? executor.execute(.resetAuto)
        TFLogger.shared.info("App launched — fans reset to auto")

        // Clean expired logs
        ThermalLogger.cleanExpired()

        startMonitoring()
        startHeartbeat()
    }

    deinit {
        heartbeatTimer?.invalidate()
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        let client = DaemonClient()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            _ = try? client.send("heartbeat")
        }
    }

    // MARK: - Monitoring

    func startMonitoring() {
        guard let fc = try? FanControl() else { return }

        let monitor = ThermalMonitor(fanControl: fc, profile: activeProfile)
        monitor.onUpdate = { [weak self] status, profile, state in
            Task { @MainActor [weak self] in
                self?.latestStatus = status
                self?.activeProfile = profile
                self?.monitorState = state
                // Max of only the displayed sensors
                // Peak across all CPU and GPU sensors for menu bar display
                let displayPrefixes = ["TC", "Tp", "TG", "Tg"]
                self?.maxTemp = status.temperatures
                    .filter { key, _ in displayPrefixes.contains(where: { key.hasPrefix($0) }) }
                    .values.max()
            }
        }
        monitor.onFanCommand = { [weak self] command in
            Task { @MainActor [weak self] in
                try self?.executor.execute(command)
            }
        }
        monitor.start()
        self.monitor = monitor
    }

    // MARK: - Actions

    func setSmart() {
        applyProfile(.smart)
    }

    func resetAuto() {
        do {
            try executor.execute(.resetAuto)
            baseProfile = .silent
            activeProfile = .silent
            monitor?.switchProfile(.silent)
            TFLogger.shared.profile("Reset to Default (Silent (Apple Default))")
        } catch {
            TFLogger.shared.error("Reset to Default failed: \(error)")
        }
    }

    func selectProfile(_ profile: FanProfile) {
        applyProfile(profile)
    }

    /// Apply a base profile, transforming it through Extra Cool when enabled.
    /// `Silent` is hands-off and ignores Extra Cool.
    private func applyProfile(_ base: FanProfile) {
        baseProfile = base
        activeProfile = base
        let effective = extraCool ? base.extraCool() : base
        monitor?.switchProfile(effective)

        let cool = (extraCool && !base.curve.handsOff) ? " (Extra Cool)" : ""
        TFLogger.shared.profile("Selected: \(base.name)\(cool)")

        // Reset the hardware to auto on every (re)apply. switchProfile() above
        // resets the monitor's fan state to "off", so without this the daemon
        // could keep the fans at a stale manual RPM while the monitor believes
        // they are off — e.g. when toggling Extra Cool shifts the start
        // threshold past the current temperature. tick() re-engages within one
        // cycle, so the only cost is a brief return to Apple's curve.
        do {
            try executor.execute(.resetAuto)
        } catch {
            TFLogger.shared.error("Profile \(base.name) failed: \(error)")
        }
    }

    // MARK: - Launch at Login

    private func updateLoginItem() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            TFLogger.shared.error("Launch at login toggle failed: \(error)")
            launchAtLogin = !launchAtLogin // revert toggle
        }
    }
}
