//
//  ThermalMonitor.swift
//  ThermalForge
//
//  Polling engine that reads temperatures and applies fan profiles.
//
//  Dual-cadence design:
//  - Thermal tick (100ms): read temps, calculate curve, apply ramp governor, write fan speed
//  - Monitor tick (2s): process capture, anomaly detection, history logging
//

import Darwin
import Foundation

// MARK: - Fan Commands

public enum FanCommand: Equatable {
    case setMax
    case setRPM(Float)
    case resetAuto
}

// MARK: - Monitor State

public enum MonitorState: Equatable {
    case idle
    case active(profileName: String)
    case safetyOverride
}

// MARK: - Thermal Monitor

public final class ThermalMonitor {
    private let sensorProvider: SensorProvider
    private let controlService: ControlService
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.thermalforge.monitor")

    public private(set) var activeProfile: FanProfile
    public private(set) var state: MonitorState = .idle
    public private(set) var latestStatus: ThermalStatus?

    // MARK: - Tick Timing

    /// Thermal tick interval in seconds. Fan control runs at this rate.
    private let tickInterval: Float

    /// Monitor cadence: process capture + anomaly detection every N thermal ticks.
    /// At 100ms thermal tick, 20 × 0.1s = 2 seconds.
    private static let monitorCadence = 20

    /// UI update cadence: onUpdate fires every N thermal ticks.
    /// At 100ms thermal tick, 5 × 0.1s = 500ms — smooth UI without excessive redraws.
    private static let uiUpdateCadence = 5

    private var tickCounter = 0

    // MARK: - Fan State

    private var lastAppliedRPMPercent: Float = 0
    private var fansCurrentlyRunning = false
    private var sustainedAboveCount = 0

    // MARK: - Smart Profile State

    private var tempHistory: [Float] = []

    // MARK: - Anomaly Detection

    /// Tracks temps over 30 seconds (15 readings at 2s monitor cadence)
    private var anomalyHistory: [Float] = []
    private var isCalibrating = false

    // MARK: - Process Buffer

    /// Rolling buffer — captures what was running BEFORE a spike.
    /// 15 snapshots × 2 seconds = 30 seconds of pre-spike history.
    private var processBuffer: [(timestamp: String, processes: String)] = []
    private let isoFormatter = ISO8601DateFormatter()

    /// Call this to suppress anomaly logging during calibration.
    public func setCalibrating(_ value: Bool) {
        queue.async { self.isCalibrating = value }
    }

    private var calibration: CalibrationData? = {
        guard let data = CalibrationData.load() else { return nil }
        if let error = data.validationError {
            TFLogger.shared.error("Calibration data rejected: \(error)")
            return nil
        }
        return data
    }()

    /// Called on UI update cadence (every 500ms) with updated status.
    public var onUpdate: ((ThermalStatus, FanProfile, MonitorState) -> Void)?
    /// Called when a fan command needs to be executed (may require privilege).
    public var onFanCommand: ((FanCommand) throws -> Void)?

    public init(
        sensorProvider: SensorProvider,
        profile: FanProfile = .silent,
        controlService: ControlService = ControlService()
    ) {
        self.sensorProvider = sensorProvider
        self.activeProfile = profile
        self.controlService = controlService
        self.tickInterval = 0.1
    }

    public convenience init(
        fanControl: FanControl,
        profile: FanProfile = .silent,
        controlService: ControlService = ControlService()
    ) {
        self.init(sensorProvider: fanControl, profile: profile, controlService: controlService)
    }

    public func updateRules(_ rules: [ThermalRule], enabled: Bool) {
        queue.async { [self] in
            controlService.replaceRules(rules, enabled: enabled)
        }
    }

    // MARK: - Lifecycle

    public func start(interval: TimeInterval = 0.1) {
        stop()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Update the active profile.
    public func switchProfile(_ profile: FanProfile) {
        queue.async { [self] in
            activeProfile = profile
            lastAppliedRPMPercent = 0
            fansCurrentlyRunning = false
            sustainedAboveCount = 0
            tickCounter = 0

            if profile.id == "smart" {
                // Reset Smart state and reload calibration data.
                tempHistory.removeAll()
                let loaded = CalibrationData.load()
                if let error = loaded?.validationError {
                    TFLogger.shared.error("Calibration data rejected on reload: \(error)")
                    calibration = nil
                } else {
                    calibration = loaded
                }
            }

            state = controlService.transition(.idle)
        }
    }

    // MARK: - Polling

    private func tick() {
        guard let status = try? sensorProvider.status() else { return }
        latestStatus = status

        // Extract peak temperatures
        // CPU: aggregate keys (M5) + per-core keys (M1-M4)
        let cpuTemp = peakTemp(status, prefixes: ["TC", "Tp"])
        // GPU: ioft keys (M5) + flt keys (M1-M4)
        let gpuTemp = peakTemp(status, prefixes: ["TG", "Tg"])
        let maxTemp = max(cpuTemp, gpuTemp)

        // Monitor cadence: process capture + anomaly detection (every 2 seconds)
        if tickCounter % Self.monitorCadence == 0 {
            monitorTick(status: status, maxTemp: maxTemp)
        }

        // Safety override: any sensor > 95°C.
        if maxTemp >= FanProfile.safetyTempThreshold {
            if state != .safetyOverride {
                applyCommand(.setMax)
                state = controlService.transition(.safetyTriggered)
                fansCurrentlyRunning = true
                lastAppliedRPMPercent = 1.0
                TFLogger.shared.safety("Override triggered: \(String(format: "%.1f", maxTemp))°C — fans maxed")
                TFLogger.shared.event(ThermalEvent(type: .safetyOverrideTriggered, details: "maxTemp=\(String(format: "%.1f", maxTemp))"))
            }
            if tickCounter % Self.uiUpdateCadence == 0 {
                onUpdate?(status, activeProfile, state)
            }
            tickCounter += 1
            return
        }

        // Clear safety override with hysteresis.
        if state == .safetyOverride
            && maxTemp < FanProfile.safetyTempThreshold - FanProfile.hysteresisDegrees
        {
            state = controlService.transition(.safetyCleared)
            TFLogger.shared.event(ThermalEvent(type: .safetyOverrideCleared, details: "maxTemp=\(String(format: "%.1f", maxTemp))"))
        }

        // Sustained trigger: track consecutive ticks above start threshold.
        let startThreshold = activeProfile.curve.startTemp
        if maxTemp >= startThreshold {
            sustainedAboveCount += 1
        } else {
            sustainedAboveCount = 0
        }

        // Rule engine preemption (after safety, before profile curve).
        let context = RuleEvaluationContext(
            cpuTemp: cpuTemp,
            gpuTemp: gpuTemp,
            maxTemp: maxTemp,
            profileID: activeProfile.id
        )
        if let decision = controlService.evaluateRules(context: context) {
            var preempted = false

            if let profileID = decision.profileID,
               let targetProfile = FanProfile.builtIn.first(where: { $0.id == profileID })
            {
                activeProfile = targetProfile
                preempted = true
            }

            if let command = decision.command {
                applyCommand(command)
                switch command {
                case .setMax:
                    lastAppliedRPMPercent = 1.0
                    fansCurrentlyRunning = true
                    state = controlService.transition(.profileActive("Rule: \(decision.sourceRuleName)"))
                case .setRPM(let rpm):
                    let maxRPM = status.fans.first.map { Float($0.maxRPM) } ?? 7826
                    lastAppliedRPMPercent = min(max(rpm / maxRPM, 0), 1)
                    fansCurrentlyRunning = rpm > 0
                    state = controlService.transition(.profileActive("Rule: \(decision.sourceRuleName)"))
                case .resetAuto:
                    lastAppliedRPMPercent = 0
                    fansCurrentlyRunning = false
                    state = controlService.transition(.idle)
                }
                preempted = true
            }

            if preempted {
                TFLogger.shared.event(ThermalEvent(type: .ruleTriggered, details: "rule=\(decision.sourceRuleID) name=\(decision.sourceRuleName)"))
                if tickCounter % Self.uiUpdateCadence == 0 {
                    onUpdate?(status, activeProfile, state)
                }
                tickCounter += 1
                return
            }
        }

        // Profile-specific logic.
        if activeProfile.id == "smart" {
            tickSmart(status: status, peakTemp: maxTemp)
        } else {
            tickCurve(status: status, peakTemp: maxTemp)
        }

        // UI update at slower cadence (every 500ms).
        if tickCounter % Self.uiUpdateCadence == 0 {
            onUpdate?(status, activeProfile, state)
        }

        tickCounter += 1
    }

    // MARK: - Monitor Cadence (every 2 seconds)

    /// Heavy operations: process capture + anomaly detection.
    /// Runs at 2-second intervals to avoid sysctl overhead at 100ms.
    private func monitorTick(status: ThermalStatus, maxTemp: Float) {
        let currentProcs = captureTopProcesses()
        let ts = isoFormatter.string(from: Date())
        processBuffer.append((timestamp: ts, processes: currentProcs))
        if processBuffer.count > 15 { processBuffer.removeFirst() }

        if !isCalibrating {
            var spikeDetected = false

            // Tier 1: instant spike — >5°C between consecutive 2-second readings.
            if let prevTemp = anomalyHistory.last {
                let instantDelta = maxTemp - prevTemp
                if abs(instantDelta) > 5 {
                    let direction = instantDelta > 0 ? "spike" : "drop"
                    let fan0 = status.fans.first
                    TFLogger.shared.info(
                        "Instant \(direction): \(String(format: "%.1f", prevTemp))→\(String(format: "%.1f", maxTemp))°C " +
                            "(\(String(format: "%+.1f", instantDelta))°C in 2s) | " +
                            "Fan0: \(fan0?.actualRPM ?? 0) RPM (\(fan0?.mode ?? "?")) | " +
                            "Profile: \(activeProfile.name)"
                    )
                    spikeDetected = true
                }
            }

            // Tier 2: sustained change — >10°C over 30 seconds.
            if anomalyHistory.count >= 15 {
                let oldest = anomalyHistory.first!
                let sustainedDelta = maxTemp - oldest
                if abs(sustainedDelta) > 10 {
                    let direction = sustainedDelta > 0 ? "spike" : "drop"
                    let fan0 = status.fans.first
                    TFLogger.shared.info(
                        "Sustained \(direction): \(String(format: "%.1f", oldest))→\(String(format: "%.1f", maxTemp))°C " +
                            "(\(String(format: "%+.1f", sustainedDelta))°C in 30s) | " +
                            "Fan0: \(fan0?.actualRPM ?? 0) RPM (\(fan0?.mode ?? "?")) | " +
                            "Profile: \(activeProfile.name)"
                    )
                    spikeDetected = true
                    anomalyHistory.removeAll()
                }
            }

            if spikeDetected {
                TFLogger.shared.info("Pre-spike process history (last \(processBuffer.count * 2)s):")
                for entry in processBuffer {
                    TFLogger.shared.info("  \(entry.timestamp): \(entry.processes)")
                }
            }
        }

        anomalyHistory.append(maxTemp)
        if anomalyHistory.count > 15 { anomalyHistory.removeFirst() }
    }

    // MARK: - Smart Profile

    private static let smartCeiling: Float = 85.0
    private static let smartFloor: Float = 53.0
    private static let smartStopTemp: Float = 50.0

    private func tickSmart(status: ThermalStatus, peakTemp: Float) {
        if tickCounter % Self.monitorCadence == 0 {
            tempHistory.append(peakTemp)
            if tempHistory.count > 4 { tempHistory.removeFirst() }
        }

        let maxRPM = status.fans.first.map { Float($0.maxRPM) } ?? 7826
        let minRPM = status.fans.first.map { Float($0.minRPM) } ?? 2317
        let minPct = minRPM / maxRPM

        if peakTemp < Self.smartStopTemp && fansCurrentlyRunning && rateOfChange() <= 0 {
            applyCommand(.resetAuto)
            lastAppliedRPMPercent = 0
            fansCurrentlyRunning = false
            state = controlService.transition(.idle)
            TFLogger.shared.fan("Smart fans off: \(String(format: "%.1f", peakTemp))°C below \(Int(Self.smartStopTemp))°C")
            return
        }

        if peakTemp < Self.smartFloor && !fansCurrentlyRunning {
            return
        }

        if peakTemp >= Self.smartStopTemp && peakTemp < Self.smartFloor && !fansCurrentlyRunning {
            return
        }

        let sustainedTicksNeeded = Int(activeProfile.curve.sustainedTriggerSec / tickInterval)
        if !fansCurrentlyRunning && sustainedAboveCount < sustainedTicksNeeded {
            if sustainedAboveCount == 1 {
                TFLogger.shared.fan("Sustained trigger: \(String(format: "%.1f", peakTemp))°C — waiting (\(sustainedAboveCount)/\(sustainedTicksNeeded)) [Smart]")
            }
            return
        }

        let rate = rateOfChange()
        var targetPct: Float

        if let cal = calibration, let calPct = cal.fanPercentForTemp(peakTemp) {
            targetPct = calPct
            if rate > 0 {
                let urgency = min(max((peakTemp - Self.smartFloor) / (Self.smartCeiling - Self.smartFloor), 0), 1)
                targetPct = min(targetPct + rate * 0.15 * (1 + urgency), 1.0)
            }
        } else {
            let range = Self.smartCeiling - Self.smartFloor
            let position = min(max((peakTemp - Self.smartFloor) / range, 0), 1)
            targetPct = position * position * (3 - 2 * position)
            if rate > 0 {
                targetPct = min(targetPct + rate * 0.2, 1.0)
            }
        }

        if peakTemp > Self.smartCeiling {
            targetPct = 1.0
        }

        targetPct = min(max(targetPct, 0), 1.0)
        if targetPct > 0 && targetPct < minPct {
            targetPct = minPct
        }

        let rampUp = activeProfile.curve.rampUpPerSec * tickInterval
        let rampDown = activeProfile.curve.rampDownPerSec * tickInterval

        if targetPct > lastAppliedRPMPercent {
            targetPct = min(targetPct, lastAppliedRPMPercent + rampUp)
        } else if targetPct < lastAppliedRPMPercent {
            targetPct = max(targetPct, lastAppliedRPMPercent - rampDown)
        }

        if abs(targetPct - lastAppliedRPMPercent) > 0.002 {
            let targetRPM = max(maxRPM * targetPct, minRPM)
            applyCommand(.setRPM(targetRPM))

            if !fansCurrentlyRunning {
                TFLogger.shared.fan("Smart fans on: \(Int(targetRPM)) RPM at \(String(format: "%.1f", peakTemp))°C")
            }

            lastAppliedRPMPercent = targetPct
            fansCurrentlyRunning = true
            state = controlService.transition(.profileActive("Smart"))
        } else if fansCurrentlyRunning {
            state = controlService.transition(.profileActive("Smart"))
        }
    }

    /// Temperature rate of change in °C per second (smoothed over history).
    /// History is sampled at monitor cadence (2s), so this covers ~8 seconds.
    private func rateOfChange() -> Float {
        guard tempHistory.count >= 2 else { return 0 }
        let oldest = tempHistory.first!
        let newest = tempHistory.last!
        let seconds = Float(tempHistory.count - 1) * Float(Self.monitorCadence) * tickInterval
        return (newest - oldest) / seconds
    }

    // MARK: - Curve-Based Profiles

    private func tickCurve(status: ThermalStatus, peakTemp: Float) {
        let curve = activeProfile.curve
        let maxRPM = status.fans.first.map { Float($0.maxRPM) } ?? 7826
        let minRPM = status.fans.first.map { Float($0.minRPM) } ?? 2317

        if curve.handsOff {
            if fansCurrentlyRunning {
                applyCommand(.resetAuto)
                fansCurrentlyRunning = false
                lastAppliedRPMPercent = 0
                state = controlService.transition(.idle)
            }
            return
        }

        guard let rawTarget = curve.targetPercent(at: peakTemp, fansCurrentlyRunning: fansCurrentlyRunning) else {
            if fansCurrentlyRunning {
                applyCommand(.resetAuto)
                fansCurrentlyRunning = false
                lastAppliedRPMPercent = 0
                state = controlService.transition(.idle)
                TFLogger.shared.fan("Fans off: \(String(format: "%.1f", peakTemp))°C below \(Int(curve.stopTemp))°C [\(activeProfile.name)]")
            }
            return
        }

        let sustainedTicksNeeded = Int(curve.sustainedTriggerSec / tickInterval)
        if !fansCurrentlyRunning && sustainedAboveCount < sustainedTicksNeeded {
            if sustainedAboveCount == 1 {
                TFLogger.shared.fan("Sustained trigger: \(String(format: "%.1f", peakTemp))°C — waiting (\(sustainedAboveCount)/\(sustainedTicksNeeded)) [\(activeProfile.name)]")
            }
            return
        }

        var targetPct = rawTarget <= 0.001 ? minRPM / maxRPM : rawTarget
        targetPct = min(max(targetPct, minRPM / maxRPM), curve.maxRPMPercent)

        let rampUp = curve.rampUpPerSec * tickInterval
        let rampDown = curve.rampDownPerSec * tickInterval

        if targetPct > lastAppliedRPMPercent {
            if !curve.instantEngage {
                targetPct = min(targetPct, lastAppliedRPMPercent + rampUp)
            }
        } else if targetPct < lastAppliedRPMPercent {
            targetPct = max(targetPct, lastAppliedRPMPercent - rampDown)
        }

        if abs(targetPct - lastAppliedRPMPercent) > 0.002 {
            let targetRPM = max(maxRPM * targetPct, minRPM)
            applyCommand(.setRPM(targetRPM))

            if !fansCurrentlyRunning {
                TFLogger.shared.fan("Fans on: \(Int(targetRPM)) RPM at \(String(format: "%.1f", peakTemp))°C [\(activeProfile.name)]")
            }

            lastAppliedRPMPercent = targetPct
            fansCurrentlyRunning = true
            state = controlService.transition(.profileActive(activeProfile.name))
        } else if fansCurrentlyRunning {
            state = controlService.transition(.profileActive(activeProfile.name))
        }
    }

    // MARK: - Process Capture

    /// Capture top 5 processes by CPU for anomaly logging.
    private func captureTopProcesses() -> String {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return "unavailable" }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return "unavailable" }

        let actualCount = size / MemoryLayout<kinfo_proc>.stride
        var results: [(name: String, cpu: Double)] = []

        for i in 0..<actualCount {
            let proc = procs[i]
            let pid = proc.kp_proc.p_pid
            guard pid > 0 else { continue }

            let name = withUnsafePointer(to: proc.kp_proc.p_comm) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                    String(cString: $0)
                }
            }

            guard !name.isEmpty, name != "kernel_task" else { continue }
            let cpuPct = Double(proc.kp_proc.p_pctcpu) / 100.0
            if cpuPct > 0.1 {
                results.append((name, cpuPct))
            }
        }

        let top5 = results.sorted { $0.cpu > $1.cpu }.prefix(5)
        if top5.isEmpty { return "idle" }
        return top5.map { "\($0.name)(\(String(format: "%.1f", $0.cpu))%)" }.joined(separator: ", ")
    }

    // MARK: - Helpers

    private func peakTemp(_ status: ThermalStatus, prefixes: [String]) -> Float {
        status.temperatures
            .filter { key, _ in prefixes.contains(where: { key.hasPrefix($0) }) }
            .values.max() ?? 0
    }

    private func applyCommand(_ command: FanCommand) {
        do {
            try onFanCommand?(command)
        } catch {
            TFLogger.shared.error("Fan command failed: \(command) — \(error)")
        }
    }
}
