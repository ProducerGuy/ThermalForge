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

    @Published var launchAtLogin: Bool = false {
        didSet { updateLoginItem() }
    }

    @Published var rulesEnabled: Bool = UserDefaults.standard.object(forKey: "rulesEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(rulesEnabled, forKey: "rulesEnabled")
            pushRulesToMonitor()
        }
    }

    @Published var rules: [ThermalRule] = [] {
        didSet {
            persistRules()
            pushRulesToMonitor()
        }
    }

    private var monitor: ThermalMonitor?
    private let executor = PrivilegedExecutor()
    private var heartbeatTimer: Timer?

    init() {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)

        // Clean state: reset fans to auto on every launch.
        try? executor.execute(.resetAuto)
        TFLogger.shared.info("App launched — fans reset to auto")

        // Clean expired logs.
        ThermalLogger.cleanExpired()

        rules = RulePersistence.load()

        startMonitoring()
        startHeartbeat()
    }

    deinit {
        heartbeatTimer?.invalidate()
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            do {
                try self?.executor.heartbeat()
            } catch {
                TFLogger.shared.error("Heartbeat failed: \(error)")
            }
        }
    }

    // MARK: - Monitoring

    func startMonitoring() {
        guard let fc = try? FanControl() else { return }

        let ruleEngine = RuleEngine(rules: rules, isEnabled: rulesEnabled)
        let controlService = ControlService(ruleEngine: ruleEngine)
        let monitor = ThermalMonitor(fanControl: fc, profile: activeProfile, controlService: controlService)

        monitor.onUpdate = { [weak self] status, profile, state in
            Task { @MainActor [weak self] in
                self?.latestStatus = status
                self?.activeProfile = profile
                self?.monitorState = state
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

    private func pushRulesToMonitor() {
        monitor?.updateRules(rules, enabled: rulesEnabled)
    }

    private func persistRules() {
        do {
            try RulePersistence.save(rules)
        } catch {
            TFLogger.shared.error("Failed to persist rules: \(error)")
        }
    }

    // MARK: - Actions

    func setSmart() {
        selectProfile(.smart)
    }

    func resetAuto() {
        do {
            try executor.execute(.resetAuto)
            activeProfile = .silent
            monitor?.switchProfile(.silent)
            TFLogger.shared.profile("Reset to Default (Silent (Apple Default))")
        } catch {
            TFLogger.shared.error("Reset to Default failed: \(error)")
        }
    }

    func selectProfile(_ profile: FanProfile) {
        activeProfile = profile
        monitor?.switchProfile(profile)
        TFLogger.shared.profile("Selected: \(profile.name)")

        do {
            if profile.curve.handsOff || profile.id == "silent" {
                try executor.execute(.resetAuto)
            }
        } catch {
            TFLogger.shared.error("Profile \(profile.name) failed: \(error)")
        }
    }

    func addQuickRule() {
        let rule = ThermalRule(
            name: "IF temp ≥ 55°C THEN 100% until ≤ 65°C",
            enabled: true,
            priority: 900,
            condition: ThermalRuleCondition(metric: .maxTemp, comparator: .greaterThanOrEqual, valueCelsius: 55),
            action: .setMax,
            untilTempBelowC: 65
        )
        rules.append(rule)
    }

    func removeRule(_ id: String) {
        rules.removeAll(where: { $0.id == id })
    }

    func toggleRule(_ id: String, enabled: Bool) {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[idx].enabled = enabled
    }

    func moveRule(_ id: String, toPriority priority: Int) {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[idx].priority = priority
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
            launchAtLogin = !launchAtLogin
        }
    }
}
