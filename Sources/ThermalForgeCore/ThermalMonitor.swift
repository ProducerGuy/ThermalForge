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
    private let fanControl: FanControl
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.thermalforge.monitor", qos: .utility)

    public private(set) var activeProfile: FanProfile
    public private(set) var state: MonitorState = .idle
    public private(set) var latestStatus: ThermalStatus?

    // MARK: - Tick Timing

    /// Thermal tick interval in seconds. Fan control runs at this rate.
    /// Set from `start(interval:)` so the ramp / sustained-trigger math (which
    /// divides by it) always matches the real timer rate.
    private var tickInterval: Float = 1.0

    /// Process capture + anomaly detection run every ~2 seconds, regardless of
    /// the tick rate. Derived from tickInterval so the wall-clock cadence holds.
    private var monitorCadence: Int { max(1, Int((2.0 / tickInterval).rounded())) }

    /// onUpdate / full-status build run every ~500ms. monitorCadence is always
    /// a multiple of this (2.0 / 0.5 == 4), so a full status exists on monitor ticks.
    private var uiUpdateCadence: Int { max(1, Int((0.5 / tickInterval).rounded())) }

    /// Below this peak temperature the rolling process buffer isn't worth its
    /// sysctl sweep — skip process capture at idle. (°C)
    private static let processCaptureFloor: Float = 50.0

    // MARK: - Adaptive cadence

    /// Fast poll rate, from `start(interval:)`. Used while warm or active.
    private var activeInterval: Float = 0.25
    /// Slow poll rate while idle. Idle CPU is dominated by SMC reads, so fewer
    /// ticks ≈ proportionally less idle CPU.
    private static let idleInterval: Float = 2.0
    /// Hands-off profiles (Silent) never control fans — Apple's thermald does —
    /// so we only poll for the menu-bar readout and the 95°C safety backup.
    /// Both tolerate a much slower idle poll, which is the single biggest idle
    /// CPU lever for the default profile.
    private static let handsOffIdleInterval: Float = 5.0
    /// Stay fast at/above this temp regardless of profile, so the 95°C safety
    /// override reacts promptly. Apple Silicon idles ~45–60°C — overlapping the
    /// profile start temps — so a plain temp threshold can never relax. The real
    /// "can slow down" signal is state-based: fans off, idle, and below this
    /// profile's start temp (sustainedAboveCount == 0).
    private static let safetyWatchTemp: Float = 85.0
    /// Require this many consecutive idle ticks before relaxing, so hovering at a
    /// start temp doesn't flap the timer. Returns to fast immediately on activity.
    private static let idleConfirmTicks = 8
    private var consecutiveIdleTicks = 0

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

    /// Called on UI update cadence (every 500ms) with updated status
    public var onUpdate: ((ThermalStatus, FanProfile, MonitorState) -> Void)?
    /// Called when a fan command needs to be executed (may require privilege)
    public var onFanCommand: ((FanCommand) throws -> Void)?

    public init(fanControl: FanControl, profile: FanProfile = .silent) {
        self.fanControl = fanControl
        self.activeProfile = profile
    }

    // MARK: - Lifecycle

    public func start(interval: TimeInterval = 1.0) {
        stop()

        activeInterval = Float(interval)
        tickInterval = activeInterval
        consecutiveIdleTicks = 0

        let timer = DispatchSource.makeTimerSource(queue: queue)
        scheduleTimer(timer, interval: tickInterval)
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

    /// (Re)schedule the repeating timer. Leeway lets the OS coalesce wakeups —
    /// a big idle-CPU win for a low-frequency poll; ±20% is invisible to fans.
    private func scheduleTimer(_ timer: DispatchSourceTimer, interval: Float) {
        timer.schedule(
            deadline: .now() + Double(interval),
            repeating: Double(interval),
            leeway: .milliseconds(Int(interval * 200))
        )
    }

    /// Adjust the poll rate to match thermal activity. Fast while warm/active so
    /// fan control and the 95°C override stay responsive; slow while cool & idle
    /// to keep idle CPU near zero. Reschedules the timer only on a real change.
    private func applyCadence(maxTemp: Float, fanChanged: Bool) {
        // Fast polling is only useful when something is *moving*: the fan speed
        // just changed (ramping), we're counting toward turning fans on, or
        // we're near the safety ceiling. Fans merely running at a STEADY speed
        // doesn't need 4–10 Hz — so a warm idle on Performance (fans holding at
        // minimum at ~56°C) relaxes to the slow rate instead of polling fast.
        let engaging = !activeProfile.curve.handsOff && !fansCurrentlyRunning && sustainedAboveCount > 0
        let busy = fanChanged
            || engaging
            || state == .safetyOverride
            || maxTemp >= Self.safetyWatchTemp

        if busy {
            consecutiveIdleTicks = 0
        } else if consecutiveIdleTicks < Self.idleConfirmTicks {
            consecutiveIdleTicks += 1
        }

        // handsOff profiles never adjust fans → slowest idle rate; fan-controlling
        // profiles holding steady use the medium rate so they still catch a rise.
        let idleRate = activeProfile.curve.handsOff ? Self.handsOffIdleInterval : Self.idleInterval
        let wantFast = busy || consecutiveIdleTicks < Self.idleConfirmTicks
        let desired = wantFast ? activeInterval : max(idleRate, activeInterval)
        guard desired != tickInterval, let timer else { return }
        tickInterval = desired
        scheduleTimer(timer, interval: desired)
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

            state = .idle
        }
    }

    // MARK: - Polling

    private func tick() {
        // Build the full sensor snapshot only on the UI/monitor cadence (the UI
        // and 2s monitor tick consume it). On those ticks, derive the control
        // peak from it instead of re-reading the CPU/GPU sensors; on the other
        // (control-only) ticks do the cheap CPU/GPU-only read.
        let status = tickCounter % uiUpdateCadence == 0 ? try? fanControl.status() : nil
        let maxTemp: Float
        if let status {
            latestStatus = status
            maxTemp = status.temperatures
                .filter { key, _ in
                    key.hasPrefix("TC") || key.hasPrefix("Tp") || key.hasPrefix("TG") || key.hasPrefix("Tg")
                }
                .values.max() ?? 0
        } else if let temps = fanControl.controlTemps() {
            maxTemp = max(temps.cpu, temps.gpu)
        } else {
            return
        }

        // Monitor cadence: process capture + anomaly detection (every 2 seconds)
        if tickCounter % monitorCadence == 0, let status {
            monitorTick(status: status, maxTemp: maxTemp)
        }

        // Safety override: any CPU/GPU sensor > 95°C
        if maxTemp >= FanProfile.safetyTempThreshold {
            if state != .safetyOverride {
                applyCommand(.setMax)
                state = .safetyOverride
                fansCurrentlyRunning = true
                lastAppliedRPMPercent = 1.0
                TFLogger.shared.safety("Override triggered: \(String(format: "%.1f", maxTemp))°C — fans maxed")
            }
            if let status { onUpdate?(status, activeProfile, state) }
            applyCadence(maxTemp: maxTemp, fanChanged: true)
            tickCounter += 1
            return
        }

        // Clear safety override with hysteresis
        if state == .safetyOverride
            && maxTemp < FanProfile.safetyTempThreshold - FanProfile.hysteresisDegrees
        {
            state = .idle
        }

        // Sustained trigger: track consecutive ticks above start threshold.
        // Per-profile duration — converted to tick count at runtime.
        let startThreshold = activeProfile.curve.startTemp
        if maxTemp >= startThreshold {
            sustainedAboveCount += 1
        } else {
            sustainedAboveCount = 0
        }

        // Profile-specific logic — fan min/max are firmware-static (cached).
        // Track whether the applied fan speed actually moved this tick: that's
        // the signal for fast polling (ramping) vs relaxing (holding steady).
        let appliedBefore = lastAppliedRPMPercent
        let runningBefore = fansCurrentlyRunning
        let limits = fanControl.primaryFanLimits()
        if activeProfile.id == "smart" {
            tickSmart(peakTemp: maxTemp, minRPM: limits.minRPM, maxRPM: limits.maxRPM)
        } else {
            tickCurve(peakTemp: maxTemp, minRPM: limits.minRPM, maxRPM: limits.maxRPM)
        }
        let fanChanged = lastAppliedRPMPercent != appliedBefore || fansCurrentlyRunning != runningBefore

        // UI update at slower cadence (every 500ms)
        if let status { onUpdate?(status, activeProfile, state) }

        applyCadence(maxTemp: maxTemp, fanChanged: fanChanged)
        tickCounter += 1
    }

    // MARK: - Monitor Cadence (every 2 seconds)

    /// Heavy operations: process capture + anomaly detection.
    /// Runs at 2-second intervals to avoid sysctl overhead at 100ms.
    private func monitorTick(status: ThermalStatus, maxTemp: Float) {
        // Rolling process buffer — captures what was running BEFORE a spike, but
        // only while the machine is warm enough for one to matter. At true idle
        // the sysctl(KERN_PROC_ALL) sweep is pure overhead, so skip it and drop
        // any stale snapshots. Anomaly detection below still runs every cycle.
        if maxTemp >= Self.processCaptureFloor {
            let currentProcs = captureTopProcesses()
            let ts = isoFormatter.string(from: Date())
            processBuffer.append((timestamp: ts, processes: currentProcs))
            if processBuffer.count > 15 { processBuffer.removeFirst() }
        } else if !processBuffer.isEmpty {
            processBuffer.removeAll()
        }

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
    }

    // MARK: - Smart Profile

    /// Target temperature ceiling — keep below this to avoid any throttling
    private static let smartCeiling: Float = 85.0
    /// Smart starts earlier than other profiles to get ahead of rising temps
    private static let smartFloor: Float = 53.0

    /// All profiles share the same off threshold — 50°C matches Apple's observed stop range
    private static let smartStopTemp: Float = 50.0

    private func tickSmart(peakTemp: Float, minRPM: Float, maxRPM: Float) {
        // Sample temperature history at monitor cadence (2s) for stable rate-of-change
        if tickCounter % monitorCadence == 0 {
            tempHistory.append(peakTemp)
            if tempHistory.count > 4 { tempHistory.removeFirst() }
        }

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

        // In hysteresis band (50-53°C): maintain current state
        if peakTemp >= Self.smartStopTemp && peakTemp < Self.smartFloor && !fansCurrentlyRunning {
            return
        }

        // Sustained trigger: per-profile duration
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
            // Calibrated: use machine-specific temp→fan lookup
            targetPct = calPct

            if rate > 0 {
                // Rising: boost proportionally to rate and proximity to ceiling
                let urgency = min(max((peakTemp - Self.smartFloor) / (Self.smartCeiling - Self.smartFloor), 0), 1)
                targetPct = min(targetPct + rate * 0.15 * (1 + urgency), 1.0)
            }
        } else {
            // Uncalibrated: S-curve (matches profile curveShape)
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

        // Ramp governors — per-profile rates, per-tick amounts
        let rampUp = activeProfile.curve.rampUpPerSec * tickInterval
        let rampDown = activeProfile.curve.rampDownPerSec * tickInterval

        if targetPct > lastAppliedRPMPercent {
            targetPct = min(targetPct, lastAppliedRPMPercent + rampUp)
        } else if targetPct < lastAppliedRPMPercent {
            targetPct = max(targetPct, lastAppliedRPMPercent - rampDown)
        }

        // Apply if changed meaningfully (threshold scaled for 100ms ticks)
        if abs(targetPct - lastAppliedRPMPercent) > 0.002 {
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

    /// Temperature rate of change in °C per second (smoothed over history).
    /// History is sampled at monitor cadence (2s), so this covers ~8 seconds.
    private func rateOfChange() -> Float {
        guard tempHistory.count >= 2 else { return 0 }
        let oldest = tempHistory.first!
        let newest = tempHistory.last!
        // tempHistory sampled at monitor cadence (2s intervals)
        let seconds = Float(tempHistory.count - 1) * Float(monitorCadence) * tickInterval
        return (newest - oldest) / seconds
    }

    // MARK: - Curve-Based Profiles

    private func tickCurve(peakTemp: Float, minRPM: Float, maxRPM: Float) {
        let curve = activeProfile.curve

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

        // Get target from curve (now applies curve shape: easeIn, linear, easeOut, sCurve)
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

        // Sustained trigger: per-profile duration.
        // Converted to tick count at runtime based on tick interval.
        let sustainedTicksNeeded = Int(curve.sustainedTriggerSec / tickInterval)
        if !fansCurrentlyRunning && sustainedAboveCount < sustainedTicksNeeded {
            if sustainedAboveCount == 1 {
                TFLogger.shared.fan("Sustained trigger: \(String(format: "%.1f", peakTemp))°C — waiting (\(sustainedAboveCount)/\(sustainedTicksNeeded)) [\(activeProfile.name)]")
            }
            return
        }

        // 0.001 signals "keep at minimum" (hysteresis band)
        var targetPct = rawTarget <= 0.001 ? minRPM / maxRPM : rawTarget

        // Clamp to valid range
        targetPct = min(max(targetPct, minRPM / maxRPM), curve.maxRPMPercent)

        // Ramp governors — per-profile rates, per-tick amounts
        let rampUp = curve.rampUpPerSec * tickInterval
        let rampDown = curve.rampDownPerSec * tickInterval

        if targetPct > lastAppliedRPMPercent {
            if !curve.instantEngage {
                // Governed ramp-up
                targetPct = min(targetPct, lastAppliedRPMPercent + rampUp)
            }
            // instantEngage: skip governor, jump directly to target
        } else if targetPct < lastAppliedRPMPercent {
            // Ramp-down governor always applies (even for instantEngage profiles)
            targetPct = max(targetPct, lastAppliedRPMPercent - rampDown)
        }

        // Apply if changed meaningfully (threshold scaled for 100ms ticks)
        if abs(targetPct - lastAppliedRPMPercent) > 0.002 {
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

    private func applyCommand(_ command: FanCommand) {
        do {
            try onFanCommand?(command)
        } catch {
            TFLogger.shared.error("Fan command failed: \(command) — \(error)")
        }
    }

}
