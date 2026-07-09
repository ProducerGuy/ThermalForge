//
//  AppState.swift
//  ThermalForge
//
//  Observable bridge between ThermalMonitor and SwiftUI.
//  Owns sparkline history, battery polling, thermal state tracking,
//  notification wiring, fan override, and menu bar cycling.
//

import ServiceManagement
import SwiftUI
@preconcurrency import ThermalForgeCore

// MARK: - Sparkline Buffer

struct SparklineBuffer {
    private(set) var values: [Float] = []
    let capacity: Int

    init(capacity: Int = 60) {
        self.capacity = capacity
        self.values.reserveCapacity(capacity)
    }

    mutating func append(_ value: Float) {
        if values.count >= capacity { values.removeFirst() }
        values.append(value)
    }

    var min: Float { values.min() ?? 0 }
    var max: Float { values.max() ?? 1 }
    var last: Float? { values.last }
    var isEmpty: Bool { values.isEmpty }
}

// MARK: - MenuBar Cycle Mode

enum MenuBarCycleMode: Int, CaseIterable {
    case cpuTemp = 0
    case gpuTemp = 1
    case fanRPM  = 2

    var next: MenuBarCycleMode {
        let all = MenuBarCycleMode.allCases
        let idx = (rawValue + 1) % all.count
        return all[idx]
    }
}

// MARK: - AppState

@MainActor
final class AppState: ObservableObject {

    // MARK: - Published: Core
    @Published var latestStatus: ThermalStatus?
    @Published var activeProfile: FanProfile = .silent
    @Published var monitorState: MonitorState = .idle
    @Published var maxTemp: Float?

    // MARK: - Published: Sparklines
    @Published var cpuSparkline  = SparklineBuffer(capacity: 60)
    @Published var gpuSparkline  = SparklineBuffer(capacity: 60)
    @Published var fan0Sparkline = SparklineBuffer(capacity: 60)

    // MARK: - Published: Battery
    @Published var batteryStatus: BatteryStatus? = nil
    @Published var hasBattery: Bool = false

    // MARK: - Published: Thermal Pressure
    @Published var thermalPressure: ThermalPressure = .nominal

    // MARK: - Published: Fan Override
    /// nil = profile in control; non-nil = manual fixed RPM
    @Published var fanOverrideRPM: Float? = nil
    /// Fan RPM limits for slider (populated from hardware at startup)
    @Published var fanMinRPM: Float = 1000
    @Published var fanMaxRPM: Float = 8000

    // MARK: - Published: Menu Bar Cycling
    @Published var menuBarCycleMode: MenuBarCycleMode = .cpuTemp
    @Published var menuBarCyclingEnabled: Bool = UserDefaults.standard.bool(forKey: "menuBarCyclingEnabled") {
        didSet {
            UserDefaults.standard.set(menuBarCyclingEnabled, forKey: "menuBarCyclingEnabled")
            menuBarCyclingEnabled ? startCycleTimer() : stopCycleTimer()
        }
    }

    // MARK: - Published: Preferences
    @Published var useFahrenheit: Bool = UserDefaults.standard.bool(forKey: "useFahrenheit") {
        didSet { UserDefaults.standard.set(useFahrenheit, forKey: "useFahrenheit") }
    }
    @Published var launchAtLogin: Bool = false {
        didSet { updateLoginItem() }
    }

    // MARK: - Private
    private var monitor: ThermalMonitor?
    let executor = PrivilegedExecutor()   // internal so views can call it directly
    private var heartbeatTimer: Timer?
    private var batteryTimer: Timer?
    private var cycleTimer: Timer?

    private var previousBatteryStatus: BatteryStatus? = nil
    private var previousThermalPressure: ThermalPressure = .nominal
    private var wasSafetyOverride = false

    // MARK: - Init

    init() {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        try? executor.execute(.resetAuto)
        TFLogger.shared.info("App launched — fans reset to auto")
        ThermalLogger.cleanExpired()
        NotificationManager.shared.requestPermission()
        startMonitoring()
        startHeartbeat()
        startBatteryPolling()
        if menuBarCyclingEnabled { startCycleTimer() }
    }

    deinit {
        heartbeatTimer?.invalidate()
        batteryTimer?.invalidate()
        cycleTimer?.invalidate()
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        let client = DaemonClient()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            _ = try? client.send("heartbeat")
        }
    }

    // MARK: - Battery Polling (30s)

    private func startBatteryPolling() {
        pollBattery()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollBattery() }
        }
    }

    private func pollBattery() {
        let status = BatteryMonitor.shared.read()
        let present = status?.isPresent ?? false
        hasBattery = present
        if present, let status = status {
            let alerts = BatteryMonitor.shared.alerts(previous: previousBatteryStatus, current: status)
            for alert in alerts {
                NotificationManager.shared.fireBatteryAlert(alert)
                TFLogger.shared.info("Battery alert: \(alert)")
            }
            previousBatteryStatus = status
            batteryStatus = status
        } else {
            batteryStatus = nil
        }
    }

    // MARK: - Menu Bar Cycling (3s rotation)

    private func startCycleTimer() {
        cycleTimer?.invalidate()
        cycleTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.menuBarCyclingEnabled else { return }
                self.menuBarCycleMode = self.menuBarCycleMode.next
            }
        }
    }

    private func stopCycleTimer() {
        cycleTimer?.invalidate()
        cycleTimer = nil
        menuBarCycleMode = .cpuTemp
    }

    // MARK: - Monitoring

    func startMonitoring() {
        guard let fc = try? FanControl() else { return }
        if let fan0 = try? fc.fanInfo(0) {
            fanMinRPM = fan0.minRPM
            fanMaxRPM = fan0.maxRPM
        }

        let monitor = ThermalMonitor(fanControl: fc, profile: activeProfile)
        monitor.onUpdate = { [weak self] status, profile, state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.latestStatus = status
                self.activeProfile = profile
                self.monitorState = state

                let displayPrefixes = ["TC", "Tp", "TG", "Tg"]
                let peakCPU = status.temperatures
                    .filter { k, _ in k.hasPrefix("TC") || k.hasPrefix("Tp") }.values.max()
                let peakGPU = status.temperatures
                    .filter { k, _ in k.hasPrefix("TG") || k.hasPrefix("Tg") }.values.max()
                self.maxTemp = status.temperatures
                    .filter { key, _ in displayPrefixes.contains(where: { key.hasPrefix($0) }) }.values.max()

                if let cpu = peakCPU { self.cpuSparkline.append(cpu) }
                if let gpu = peakGPU { self.gpuSparkline.append(gpu) }
                if let rpm = status.fans.first.map({ Float($0.actualRPM) }) { self.fan0Sparkline.append(rpm) }

                self.thermalPressure = status.thermalPressure
                self.handleThermalPressureChange(status.thermalPressure)
                self.handleSafetyOverrideChange(state: state, maxTemp: self.maxTemp ?? 0)
            }
        }
        monitor.onFanCommand = { [weak self] command in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Block profile fan commands when user has a manual override active
                if self.fanOverrideRPM == nil {
                    try self.executor.execute(command)
                }
            }
        }
        monitor.onAnomaly = { [weak self] kind, fromTemp, toTemp, deltaSeconds in
            Task { @MainActor [weak self] in
                guard self != nil else { return }
                NotificationManager.shared.fireTempAnomaly(
                    kind: kind, fromTemp: fromTemp, toTemp: toTemp, deltaSeconds: deltaSeconds)
            }
        }
        monitor.start()
        self.monitor = monitor
    }

    // MARK: - Fan Override

    func setFanOverride(rpm: Float) {
        do {
            try executor.execute(.setRPM(rpm))
            fanOverrideRPM = rpm
            TFLogger.shared.fan("Manual override: \(Int(rpm)) RPM")
        } catch {
            TFLogger.shared.error("Fan override failed: \(error)")
        }
    }

    func releaseFanOverride() {
        do {
            try executor.execute(.resetAuto)
            fanOverrideRPM = nil
            TFLogger.shared.fan("Manual override released — profile resumed")
        } catch {
            TFLogger.shared.error("Fan override release failed: \(error)")
        }
    }

    // MARK: - Thermal Pressure Notifications

    private func handleThermalPressureChange(_ newPressure: ThermalPressure) {
        let prev = previousThermalPressure
        previousThermalPressure = newPressure
        switch (prev, newPressure) {
        case (.nominal, .serious), (.fair, .serious), (.nominal, .critical), (.fair, .critical):
            NotificationManager.shared.fireThermalThrottle(level: newPressure.rawValue)
            TFLogger.shared.info("Thermal pressure escalated: \(prev.rawValue) → \(newPressure.rawValue)")
        case (.serious, .nominal), (.serious, .fair), (.critical, .nominal), (.critical, .fair):
            NotificationManager.shared.fireThermalThrottleCleared()
            TFLogger.shared.info("Thermal pressure cleared: \(prev.rawValue) → \(newPressure.rawValue)")
        default: break
        }
    }

    private func handleSafetyOverrideChange(state: MonitorState, maxTemp: Float) {
        let isSafetyNow = (state == .safetyOverride)
        if isSafetyNow && !wasSafetyOverride { NotificationManager.shared.fireSafetyOverride(temp: maxTemp) }
        else if !isSafetyNow && wasSafetyOverride { NotificationManager.shared.fireSafetyCleared(temp: maxTemp) }
        wasSafetyOverride = isSafetyNow
    }
    // MARK: - Actions

    func setSmart() {
        activeProfile = .smart
        monitor?.switchProfile(.smart)
        TFLogger.shared.profile("Smart activated")
    }

    func resetAuto() {
        fanOverrideRPM = nil
        do {
            try executor.execute(.resetAuto)
            activeProfile = .silent
            monitor?.switchProfile(.silent)
            TFLogger.shared.profile("Reset to Default")
        } catch {
            TFLogger.shared.error("Reset to Default failed: \(error)")
        }
    }

    func selectProfile(_ profile: FanProfile) {
        fanOverrideRPM = nil
        activeProfile = profile
        monitor?.switchProfile(profile)
        TFLogger.shared.profile("Selected: \(profile.name)")
        do {
            if profile.curve.handsOff || profile.id == "smart" || profile.id == "silent" {
                try executor.execute(.resetAuto)
            }
        } catch {
            TFLogger.shared.error("Profile \(profile.name) failed: \(error)")
        }
    }

    // MARK: - Launch at Login

    private func updateLoginItem() {
        do {
            if launchAtLogin { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            TFLogger.shared.error("Launch at login toggle failed: \(error)")
            launchAtLogin = !launchAtLogin
        }
    }

    // MARK: - Helpers

    var peakCPUTemp: Float? {
        latestStatus?.temperatures
            .filter { k, _ in k.hasPrefix("TC") || k.hasPrefix("Tp") }.values.max()
    }

    var peakGPUTemp: Float? {
        latestStatus?.temperatures
            .filter { k, _ in k.hasPrefix("TG") || k.hasPrefix("Tg") }.values.max()
    }

    func deltaT(for tempC: Float) -> Float? {
        guard let ambient = latestStatus?.ambientTemp, ambient > 0 else { return nil }
        return tempC - ambient
    }

    func displayTemp(_ tempC: Float) -> String {
        let value = useFahrenheit ? tempC * 9/5 + 32 : tempC
        return String(format: "%.1f°\(useFahrenheit ? "F" : "C")", value)
    }

    /// Menu bar label text for current cycle mode
    var menuBarLabel: String {
        guard let status = latestStatus else { return "" }
        switch menuBarCycleMode {
        case .cpuTemp:
            let t = status.temperatures
                .filter { k, _ in k.hasPrefix("TC") || k.hasPrefix("Tp") }.values.max() ?? 0
            let d = useFahrenheit ? t * 9/5 + 32 : t
            return "\(Int(d))°"
        case .gpuTemp:
            let t = status.temperatures
                .filter { k, _ in k.hasPrefix("TG") || k.hasPrefix("Tg") }.values.max() ?? 0
            let d = useFahrenheit ? t * 9/5 + 32 : t
            return "G\(Int(d))°"
        case .fanRPM:
            let rpm = status.fans.first?.actualRPM ?? 0
            return "\(rpm)rpm"
        }
    }
}
