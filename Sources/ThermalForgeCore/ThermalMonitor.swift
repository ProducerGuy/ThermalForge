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
    private var lastSmartRPMPercent: Float = 0

    // Anomaly detection — tracks temps over 30 seconds (15 readings at 2s)
    private var anomalyHistory: [Float] = []
    private var isCalibrating = false

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
                lastSmartRPMPercent = 0
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

        // Anomaly detection: log significant temperature changes
        anomalyHistory.append(maxTemp)
        if anomalyHistory.count > 15 { anomalyHistory.removeFirst() }
        if !isCalibrating && anomalyHistory.count >= 15 {
            let oldest = anomalyHistory.first!
            let delta = maxTemp - oldest
            if abs(delta) > 10 {
                let direction = delta > 0 ? "spike" : "drop"
                let fan0 = status.fans.first
                let topProcs = captureTopProcesses()
                TFLogger.shared.info(
                    "Temperature \(direction): \(String(format: "%.1f", oldest))→\(String(format: "%.1f", maxTemp))°C " +
                    "(\(String(format: "%+.1f", delta))°C in 30s) | " +
                    "Fan0: \(fan0?.actualRPM ?? 0) RPM (\(fan0?.mode ?? "?")) | " +
                    "Profile: \(activeProfile.name) | " +
                    "Processes: \(topProcs)"
                )
                // Reset so we don't log the same event repeatedly
                anomalyHistory.removeAll()
            }
        }

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
            onUpdate?(status, activeProfile, state)
            return
        }

        // All other profiles: use curve
        tickCurve(status: status, peakTemp: maxTemp)

        onUpdate?(status, activeProfile, state)
    }

    // MARK: - Smart Profile

    /// Target temperature ceiling — keep below this to avoid any throttling
    private static let smartCeiling: Float = 85.0
    /// Below this temperature, hand control back to Apple (fans off / idle)
    private static let smartFloor: Float = 60.0

    private func tickSmart(status: ThermalStatus, peakTemp: Float) {
        // Track temperature history (keep last 4 readings = 8 seconds at 2s interval)
        tempHistory.append(peakTemp)
        if tempHistory.count > 4 { tempHistory.removeFirst() }

        let maxRPM = status.fans.first.map { Float($0.maxRPM) } ?? 7826

        // Below floor: return to auto
        if peakTemp < Self.smartFloor && rateOfChange() <= 0 {
            if lastSmartRPMPercent > 0 {
                applyCommand(.resetAuto)
                lastSmartRPMPercent = 0
                state = .idle
            }
            return
        }

        let rate = rateOfChange()
        var targetPct: Float

        if let cal = calibration {
            // Calibrated path: use machine-specific data
            // Find the minimum fan level that can sustain current thermal conditions.
            // Each measurement tells us: at this fan %, the machine holds X% load below 85°C.
            let tempPosition = min(max((peakTemp - Self.smartFloor) / (Self.smartCeiling - Self.smartFloor), 0), 1)

            // Start with the lowest fan speed and go up until we find one that can handle it
            let sorted = cal.measurements.sorted { $0.rpmPercent < $1.rpmPercent }
            var basePct: Float = sorted.last?.rpmPercent ?? 1.0

            for m in sorted {
                // If maxSustainableLoad is nil (legacy data), fall back to steady state check only
                if let load = m.maxSustainableLoad {
                    // If this fan speed held full load, it can handle anything
                    if load >= 1.0 {
                        basePct = m.rpmPercent
                        break
                    }
                }
                // If steady state was well below ceiling, this level has headroom
                if m.steadyState < Self.smartCeiling - 5 {
                    basePct = m.rpmPercent
                    break
                }
            }

            // Scale by how close we are to the ceiling
            targetPct = basePct * tempPosition

            if rate > 0 {
                // Rising: boost proportionally to rate and proximity to ceiling
                let urgency = tempPosition
                targetPct = min(targetPct + rate * 0.15 * (1 + urgency), 1.0)
            } else if peakTemp > Self.smartCeiling {
                // Above ceiling: push to max
                targetPct = 1.0
            }
        } else {
            // Uncalibrated fallback: conservative S-curve
            let range = Self.smartCeiling - Self.smartFloor
            let position = min(max((peakTemp - Self.smartFloor) / range, 0), 1)
            targetPct = position * position * (3 - 2 * position)

            if rate > 0 {
                targetPct = min(targetPct + rate * 0.2, 1.0)
            }
        }

        // Clamp to valid range
        targetPct = min(max(targetPct, 0), 1.0)

        // Ramp-down governor: reduce RPM at half the rate we ramp up
        if targetPct < lastSmartRPMPercent {
            let maxDrop: Float = 0.05
            targetPct = max(targetPct, lastSmartRPMPercent - maxDrop)
        }

        // Apply if changed meaningfully (avoid SMC write spam)
        if abs(targetPct - lastSmartRPMPercent) > 0.02 {
            let minRPM = status.fans.first.map { Float($0.minRPM) } ?? 1200
            let targetRPM = max(maxRPM * targetPct, minRPM)
            applyCommand(.setRPM(targetRPM))
            lastSmartRPMPercent = targetPct
            state = .active(profileName: "Smart")
        } else if lastSmartRPMPercent > 0 {
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
            onUpdate?(status, activeProfile, state)
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
            onUpdate?(status, activeProfile, state)
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
            onUpdate?(status, activeProfile, state)
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

        onUpdate?(status, activeProfile, state)
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

    /// Read system memory pressure via Mach VM stats
    private func memoryPressure() -> Float {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<natural_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let pageSize = Float(vm_kernel_page_size)
        let total = Float(stats.active_count + stats.inactive_count
            + stats.wire_count + stats.free_count) * pageSize
        let used = Float(stats.active_count + stats.wire_count) * pageSize
        guard total > 0 else { return 0 }
        return (used / total) * 100
    }
}
