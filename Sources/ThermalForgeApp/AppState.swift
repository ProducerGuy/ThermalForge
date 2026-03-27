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
    let calibrationState = CalibrationState()

    @Published var useFahrenheit: Bool = UserDefaults.standard.bool(forKey: "useFahrenheit") {
        didSet { UserDefaults.standard.set(useFahrenheit, forKey: "useFahrenheit") }
    }
    @Published var launchAtLogin: Bool = false {
        didSet { updateLoginItem() }
    }

    private var monitor: ThermalMonitor?
    private let executor = PrivilegedExecutor()
    private var heartbeatTimer: Timer?

    init() {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        calibrationState.onComplete = { [weak self] in
            self?.activeProfile = .smart
            self?.monitor?.switchProfile(.smart)
        }
        calibrationState.onStop = { [weak self] in
            self?.activeProfile = .silent
            self?.monitor?.switchProfile(.silent)
        }
        startMonitoring()
        startHeartbeat()
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
        NSLog("ThermalForge: Smart button pressed")
        if !CalibrationData.exists && !calibrationState.isComplete {
            // No calibration data — prompt user
            calibrationState.showPrompt = true
        } else {
            activeProfile = .smart
            monitor?.switchProfile(.smart)
        }
    }

    func activateSmartAfterSkip() {
        NSLog("ThermalForge: Smart activated with default curve (calibration skipped)")
        activeProfile = .smart
        monitor?.switchProfile(.smart)
    }

    func resetAuto() {
        NSLog("ThermalForge: resetAuto button pressed")
        do {
            try executor.execute(.resetAuto)
            activeProfile = .silent
            monitor?.switchProfile(.silent)
        } catch {
            NSLog("ThermalForge: resetAuto failed: %@", "\(error)")
        }
    }

    func selectProfile(_ profile: FanProfile) {
        NSLog("ThermalForge: selecting profile: %@", profile.name)
        activeProfile = profile
        monitor?.switchProfile(profile)

        do {
            if profile.id == "smart" {
                // Smart — tick() handles fan control dynamically
                return
            } else if profile.fanBehavior.mode == .auto {
                // Silent — return to Apple defaults
                try executor.execute(.resetAuto)
            } else if profile.fanBehavior.rpmPercent >= 1.0 {
                // Max — full speed
                try executor.execute(.setMax)
            } else {
                // Balanced/Performance — apply immediately at the profile's RPM %
                let maxRPM: Float = Float(latestStatus?.fans.first?.maxRPM ?? 7826)
                let targetRPM = maxRPM * profile.fanBehavior.rpmPercent
                try executor.execute(.setRPM(targetRPM))
            }
        } catch {
            NSLog("ThermalForge: profile %@ failed: %@", profile.name, "\(error)")
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
            // Silently fail — user can retry
        }
    }
}
