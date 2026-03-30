//
//  ThermalMonitor.swift
//  ThermalForge
//
//  Polling engine that reads temperatures and applies fan profiles.
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
    private let fanControl: FanControl
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.thermalforge.monitor")

    public private(set) var activeProfile: FanProfile
    public private(set) var state: MonitorState = .idle
    public private(set) var latestStatus: ThermalStatus?

    // Curve state
    private var lastAppliedRPMPercent: Float = 0
    private var fansCurrentlyRunning = false

    /// Max ramp-up rate: ~400 RPM/sec = ~5% per 2-second tick
    /// Research: Apple ramps at ~350-550 RPM/sec. ADM1031 fastest = ~460 RPM/sec.
    private static let maxRampUp: Float = 0.05
    /// Max ramp-down rate: ~200 RPM/sec = ~2.5% per 2-second tick
    private static let maxRampDown: Float = 0.025

    // Smart profile state
    private var tempHistory: [Float] = []

    // Anomaly detection — tracks temps over 30 seconds (15 readings at 2s)
    private var anomalyHistory: [Float] = []
    private var isCalibrating = false

    // Rolling process buffer — captures what was running BEFORE a spike
    // 15 snapshots × 2 seconds = 30 seconds of pre-spike history
    private var processBuffer: [(timestamp: String, processes: String)] = []
    private let isoFormatter = ISO8601DateFormatter()

    /// Call this to suppress anomaly logging during calibration
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

    /// Called on every poll with updated status
    public var onUpdate: ((ThermalStatus, FanProfile, MonitorState) -> Void)?
    /// Called when a fan command needs to be executed (may require privilege)
    public var onFanCommand: ((FanCommand) throws -> Void)?

    public init(fanControl: FanControl, profile: FanProfile = .silent) {
        self.fanControl = fanControl
        self.activeProfile = profile
    }

    // MARK: - Lifecycle

    public func start(interval: TimeInterval = 2.0) {
        stop()

        // If profile is Max, apply immediately
        if activeProfile.id == "max" {
            applyCommand(.setMax)
            state = .active(profileName: "Max")
        }

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

            if profile.id == "smart" {
                // Reset Smart state and reload calibration data
                tempHistory.removeAll()
                let loaded = CalibrationData.load()
                if let error = loaded?.validationError {
                    TFLogger.shared.error("Calibration data rejected on reload: \(error)")
                    calibration = nil
                } else {
                    calibration = loaded
                }
            }

            if profile.curve.alwaysOn {
                state = .active(profileName: profile.name)
            } else {
                state = .idle
            }
        }
    }

    // MARK: - Polling

    private func tick() {
        guard let status = try? fanControl.status() else { return }
        latestStatus = status

        // Extract peak temperatures
        // CPU: aggregate keys (M5) + per-core keys (M1-M4)
        let cpuTemp = peakTemp(status, prefixes: ["TC", "Tp"])
        // GPU: ioft keys (M5) + flt keys (M1-M4)
        let gpuTemp = peakTemp(status, prefixes: ["TG", "Tg"])
        let maxTemp = max(cpuTemp, gpuTemp)

        // Rolling process buffer — always capturing, like a security camera
        let currentProcs = captureTopProcesses()
        let ts = isoFormatter.string(from: Date())
        processBuffer.append((timestamp: ts, processes: currentProcs))
        if processBuffer.count > 15 { processBuffer.removeFirst() }

        // Anomaly detection: two tiers
        // Tier 1: instant spike — >5°C between consecutive readings (2 seconds)
        // Tier 2: sustained change — >10°C over 30 seconds
        if !isCalibrating {
            var spikeDetected = false

            // Tier 1: check against previous reading
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

            // Tier 2: check over 30-second window
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

            // Dump the rolling buffer on any spike — shows what was running BEFORE
            if spikeDetected {
                TFLogger.shared.info("Pre-spike process history (last \(processBuffer.count * 2)s):")
                for entry in processBuffer {
                    TFLogger.shared.info("  \(entry.timestamp): \(entry.processes)")
                }
            }
        }

        anomalyHistory.append(maxTemp)
        if anomalyHistory.count > 15 { anomalyHistory.removeFirst() }

        // Safety override: any sensor > 95°C
        if maxTemp >= FanProfile.safetyTempThreshold {
            if state != .safetyOverride {
                applyCommand(.setMax)
                state = .safetyOverride
                fansCurrentlyRunning = true
                lastAppliedRPMPercent = 1.0
                TFLogger.shared.safety("Override triggered: \(String(format: "%.1f", maxTemp))°C — fans maxed")
            }
            onUpdate?(status, activeProfile, state)
            return
        }

        // Clear safety override with hysteresis
        if state == .safetyOverride
            && maxTemp < FanProfile.safetyTempThreshold - FanProfile.hysteresisDegrees
        {
            state = .idle
        }

        // Smart profile: uses curve + rate-of-change + calibration
        if activeProfile.id == "smart" {
            tickSmart(status: status, peakTemp: maxTemp)
        } else {
            // All other profiles: use curve
            tickCurve(status: status, peakTemp: maxTemp)
        }

        // Single onUpdate call per tick — never inside tickCurve/tickSmart
        onUpdate?(status, activeProfile, state)
    }

    // MARK: - Smart Profile

    /// Target temperature ceiling — keep below this to avoid any throttling
    private static let smartCeiling: Float = 85.0
    /// Below this temperature, hand control back to Apple (fans off / idle)
    private static let smartFloor: Float = 60.0

    /// Smart stop threshold: 5°C below floor for hysteresis (research: min 5°C gap)
    private static let smartStopTemp: Float = 55.0

    private func tickSmart(status: ThermalStatus, peakTemp: Float) {
        // Track temperature history (keep last 4 readings = 8 seconds at 2s interval)
        tempHistory.append(peakTemp)
        if tempHistory.count > 4 { tempHistory.removeFirst() }

        let maxRPM = status.fans.first.map { Float($0.maxRPM) } ?? 7826
        let minRPM = status.fans.first.map { Float($0.minRPM) } ?? 2317
        let minPct = minRPM / maxRPM

        // Below stop threshold and fans running: turn off (with hysteresis)
        if peakTemp < Self.smartStopTemp && fansCurrentlyRunning && rateOfChange() <= 0 {
            applyCommand(.resetAuto)
            lastAppliedRPMPercent = 0
            fansCurrentlyRunning = false
            state = .idle
            TFLogger.shared.fan("Smart fans off: \(String(format: "%.1f", peakTemp))°C below \(Int(Self.smartStopTemp))°C")
            return
        }

        // Below floor and fans not running: stay off
        if peakTemp < Self.smartFloor && !fansCurrentlyRunning {
            return
        }

        // In hysteresis band (55-60°C): maintain current state
        if peakTemp >= Self.smartStopTemp && peakTemp < Self.smartFloor && !fansCurrentlyRunning {
            return
        }

        let rate = rateOfChange()
        var targetPct: Float

        if let cal = calibration, let calPct = cal.fanPercentForTemp(peakTemp) {
            // Calibrated: use machine-specific temp→fan lookup
            targetPct = calPct

            if rate > 0 {
                // Rising: boost proportionally to rate and proximity to ceiling
                let urgency = min(max((peakTemp - Self.smartFloor) / (Self.smartCeiling - Self.smartFloor), 0), 1)
                targetPct = min(targetPct + rate * 0.15 * (1 + urgency), 1.0)
            }
        } else {
            // Uncalibrated: conservative S-curve
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

        // Clamp to valid range, enforce minimum RPM
        targetPct = min(max(targetPct, 0), 1.0)
        if targetPct > 0 && targetPct < minPct {
            targetPct = minPct
        }

        // Ramp governors (matching Apple: ~400 RPM/sec up, ~200 RPM/sec down)
        if targetPct > lastAppliedRPMPercent {
            targetPct = min(targetPct, lastAppliedRPMPercent + Self.maxRampUp)
        } else if targetPct < lastAppliedRPMPercent {
            targetPct = max(targetPct, lastAppliedRPMPercent - Self.maxRampDown)
        }

        // Apply if changed meaningfully (avoid SMC write spam)
        if abs(targetPct - lastAppliedRPMPercent) > 0.01 {
            let targetRPM = max(maxRPM * targetPct, minRPM)
            applyCommand(.setRPM(targetRPM))

            if !fansCurrentlyRunning {
                TFLogger.shared.fan("Smart fans on: \(Int(targetRPM)) RPM at \(String(format: "%.1f", peakTemp))°C")
            }

            lastAppliedRPMPercent = targetPct
            fansCurrentlyRunning = true
            state = .active(profileName: "Smart")
        } else if fansCurrentlyRunning {
            state = .active(profileName: "Smart")
        }
    }

    /// Temperature rate of change in °C per second (smoothed over history)
    private func rateOfChange() -> Float {
        guard tempHistory.count >= 2 else { return 0 }
        let oldest = tempHistory.first!
        let newest = tempHistory.last!
        let seconds = Float(tempHistory.count - 1) * 2.0 // 2s polling interval
        return (newest - oldest) / seconds
    }

    // MARK: - Curve-Based Profiles

    private func tickCurve(status: ThermalStatus, peakTemp: Float) {
        let curve = activeProfile.curve
        let maxRPM = status.fans.first.map { Float($0.maxRPM) } ?? 7826
        let minRPM = status.fans.first.map { Float($0.minRPM) } ?? 2317

        // Hands-off profiles (Silent): don't control fans, just monitor
        if curve.handsOff {
            if fansCurrentlyRunning {
                applyCommand(.resetAuto)
                fansCurrentlyRunning = false
                lastAppliedRPMPercent = 0
                state = .idle
            }
            return
        }

        // Always-on (Max): set and hold
        if curve.alwaysOn {
            if lastAppliedRPMPercent < curve.maxRPMPercent {
                applyCommand(.setMax)
                lastAppliedRPMPercent = curve.maxRPMPercent
                fansCurrentlyRunning = true
                state = .active(profileName: activeProfile.name)
            }
            return
        }

        // Get target from curve
        guard let rawTarget = curve.targetPercent(at: peakTemp, fansCurrentlyRunning: fansCurrentlyRunning) else {
            // Curve says fans should be off
            if fansCurrentlyRunning {
                applyCommand(.resetAuto)
                fansCurrentlyRunning = false
                lastAppliedRPMPercent = 0
                state = .idle
                TFLogger.shared.fan("Fans off: \(String(format: "%.1f", peakTemp))°C below \(Int(curve.stopTemp))°C [\(activeProfile.name)]")
            }
            return
        }

        // 0.001 signals "keep at minimum" (hysteresis band)
        var targetPct = rawTarget <= 0.001 ? minRPM / maxRPM : rawTarget

        // Clamp to valid range
        targetPct = min(max(targetPct, minRPM / maxRPM), curve.maxRPMPercent)

        // Apply ramp governors
        if targetPct > lastAppliedRPMPercent {
            // Ramp up: max ~400 RPM/sec
            targetPct = min(targetPct, lastAppliedRPMPercent + Self.maxRampUp)
        } else if targetPct < lastAppliedRPMPercent {
            // Ramp down: max ~200 RPM/sec
            targetPct = max(targetPct, lastAppliedRPMPercent - Self.maxRampDown)
        }

        // Apply if changed meaningfully
        if abs(targetPct - lastAppliedRPMPercent) > 0.01 {
            let targetRPM = max(maxRPM * targetPct, minRPM)
            applyCommand(.setRPM(targetRPM))

            if !fansCurrentlyRunning {
                TFLogger.shared.fan("Fans on: \(Int(targetRPM)) RPM at \(String(format: "%.1f", peakTemp))°C [\(activeProfile.name)]")
            }

            lastAppliedRPMPercent = targetPct
            fansCurrentlyRunning = true
            state = .active(profileName: activeProfile.name)
        } else if fansCurrentlyRunning {
            state = .active(profileName: activeProfile.name)
        }
    }

    // MARK: - Process Capture

    /// Capture top 5 processes by CPU for anomaly logging
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
