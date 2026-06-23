//
//  AppState.swift
//  ThermalForge
//
//  Observable bridge between ThermalMonitor and SwiftUI.
//

import Observation
import ServiceManagement
import SwiftUI
@preconcurrency import ThermalForgeCore

@MainActor
@Observable
final class AppState {
    var latestStatus: ThermalStatus?
    var activeProfile: FanProfile = .silent
    var monitorState: MonitorState = .idle
    var maxTemp: Float?
    var useFahrenheit: Bool = UserDefaults.standard.bool(forKey: "useFahrenheit") {
        didSet { UserDefaults.standard.set(useFahrenheit, forKey: "useFahrenheit") }
    }
    var launchAtLogin: Bool = false {
        didSet { updateLoginItem() }
    }

    @ObservationIgnored private var monitor: ThermalMonitor?
    @ObservationIgnored private let executor = PrivilegedExecutor()
    @ObservationIgnored private var heartbeatTimer: Timer?
    /// Whether the dropdown panel is currently shown. The panel's hosting view
    /// stays alive while hidden and re-renders on any observed change, so we
    /// only feed it the per-tick `latestStatus` while it's actually visible.
    @ObservationIgnored private var menuOpen = false
    @ObservationIgnored private var lastStatus: ThermalStatus?

    init() {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)

        // Clean state: reset fans to auto on every launch.
        try? executor.execute(.resetAuto)
        TFLogger.shared.info("App launched — fans reset to auto")

        // Clean expired logs
        ThermalLogger.cleanExpired()

        startMonitoring()
        // Heartbeat is started only when a fan-controlling profile is active
        // (see syncHeartbeat). The default Silent profile needs none.
    }

    deinit {
        heartbeatTimer?.invalidate()
    }

    // MARK: - Heartbeat

    /// The daemon watchdog ignores heartbeats unless a manual fan command was
    /// sent, so hands-off (Silent) needs no heartbeat — running it there is a
    /// pure 5s wake on both processes for nothing. Run it only for fan-
    /// controlling profiles.
    private func syncHeartbeat(for profile: FanProfile) {
        if profile.curve.handsOff {
            stopHeartbeat()
        } else {
            startHeartbeat()
        }
    }

    private func startHeartbeat() {
        guard heartbeatTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            // Off the main thread — a blocking daemon round-trip must never stall the UI.
            DispatchQueue.global(qos: .utility).async {
                _ = try? DaemonClient().send("heartbeat")
            }
        }
        timer.tolerance = 1.0 // let the OS coalesce the wakeup
        heartbeatTimer = timer
    }

    private func stopHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }

    // MARK: - Monitoring

    func startMonitoring() {
        guard let fc = try? FanControl() else { return }

        let monitor = ThermalMonitor(fanControl: fc, profile: activeProfile)
        monitor.onUpdate = { [weak self] status, profile, state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastStatus = status
                // Publish-on-change, AND only while the panel is visible. The
                // dropdown's hosting view stays alive when hidden and re-renders
                // on every latestStatus change — so feeding it per-tick updates
                // while closed drives full SwiftUI layout for nothing.
                if self.menuOpen, self.latestStatus != status { self.latestStatus = status }
                if self.activeProfile != profile { self.activeProfile = profile }
                if self.monitorState != state { self.monitorState = state }
                // Peak across all displayed CPU and GPU sensors for the menu bar.
                // Quantize to whole degrees: the label shows an integer, so a
                // jittering 0.1° fraction would otherwise force a relayout (CA
                // transaction) every update for a number that never changes.
                let displayPrefixes = ["TC", "Tp", "TG", "Tg"]
                let newMax = status.temperatures
                    .filter { key, _ in displayPrefixes.contains(where: { key.hasPrefix($0) }) }
                    .values.max()
                    .map { $0.rounded() }
                if self.maxTemp != newMax { self.maxTemp = newMax }
            }
        }
        // Fan commands run off the main thread, coalesced. The ramp fires
        // ~10×/s and each daemon round-trip can exceed 0.5s; routing this
        // through the main actor (as before) starved the UI run loop and froze
        // the app on profile switch.
        let executor = self.executor
        monitor.onFanCommand = { command in
            executor.submit(command)
        }
        monitor.start()
        self.monitor = monitor
    }

    // MARK: - Menu visibility

    /// Called when the dropdown panel becomes visible: resume live updates and
    /// push the latest snapshot immediately so it isn't stale on open.
    func menuDidOpen() {
        menuOpen = true
        if let status = lastStatus, latestStatus != status { latestStatus = status }
    }

    /// Called when the panel is dismissed: stop feeding the hidden hosting view.
    func menuDidClose() {
        menuOpen = false
    }

    // MARK: - Actions

    func setSmart() {
        activeProfile = .smart
        monitor?.switchProfile(.smart)
        syncHeartbeat(for: .smart)
        TFLogger.shared.profile("Smart activated")
    }

    func resetAuto() {
        do {
            try executor.execute(.resetAuto)
            activeProfile = .silent
            monitor?.switchProfile(.silent)
            stopHeartbeat()
            TFLogger.shared.profile("Reset to Default (Silent (Apple Default))")
        } catch {
            TFLogger.shared.error("Reset to Default failed: \(error)")
        }
    }

    func selectProfile(_ profile: FanProfile) {
        activeProfile = profile
        monitor?.switchProfile(profile)
        syncHeartbeat(for: profile)
        TFLogger.shared.profile("Selected: \(profile.name)")

        // All profiles use proportional curves — tick() handles fan engagement.
        // Reset to auto on profile change so tick() starts from a clean state.
        do {
            if profile.curve.handsOff || profile.id == "smart" || profile.id == "silent" {
                try executor.execute(.resetAuto)
            }
            // Balanced/Performance/Max: tick() will ramp proportionally
            // based on current temperature after sustained trigger is met
        } catch {
            TFLogger.shared.error("Profile \(profile.name) failed: \(error)")
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
