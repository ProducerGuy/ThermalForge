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
                self?.maxTemp = status.temperatures.values.max()
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
        Task {
            try? executor.execute(.setMax)
            activeProfile = .max
            monitor?.switchProfile(.max)
        }
    }

    func resetAuto() {
        Task {
            try? executor.execute(.resetAuto)
            activeProfile = .silent
            monitor?.switchProfile(.silent)
        }
    }

    func selectProfile(_ profile: FanProfile) {
        activeProfile = profile
        monitor?.switchProfile(profile)

        // Max and Silent need immediate execution
        if profile.id == "max" {
            Task { try? executor.execute(.setMax) }
        } else if profile.id == "silent" {
            Task { try? executor.execute(.resetAuto) }
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
