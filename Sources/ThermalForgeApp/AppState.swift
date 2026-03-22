//
//  AppState.swift
//  ThermalForge
//
//  Observable bridge between ThermalMonitor and SwiftUI.
//

import ServiceManagement
import SwiftUI
import ThermalForgeCore

@MainActor
final class AppState: ObservableObject {
    @Published var latestStatus: ThermalStatus?
    @Published var activeProfile: FanProfile = .silent
    @Published var monitorState: MonitorState = .idle
    @Published var maxTemp: Float?
    @Published var useFahrenheit: Bool = UserDefaults.standard.bool(forKey: "useFahrenheit") {
        didSet { UserDefaults.standard.set(useFahrenheit, forKey: "useFahrenheit") }
    }
    @Published var launchAtLogin: Bool = false {
        didSet { updateLoginItem() }
    }

    private var monitor: ThermalMonitor?
    private let executor = PrivilegedExecutor()

    init() {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        startMonitoring()
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
                let displayedKeys = ["cpu_die_max", "cpu_hotpoint", "gpu_1", "gpu_2", "gpu_3", "ram_die_max", "ssd_max", "ambient"]
                self?.maxTemp = displayedKeys.compactMap { status.temperatures[$0] }.max()
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

    func setMax() {
        NSLog("ThermalForge: setMax button pressed")
        do {
            try executor.execute(.setMax)
            activeProfile = .max
            monitor?.switchProfile(.max)
        } catch {
            NSLog("ThermalForge: setMax failed: %@", "\(error)")
        }
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
            if profile.fanBehavior.mode == .auto {
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
