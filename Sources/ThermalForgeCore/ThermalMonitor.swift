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
//  Post-override cool-down:
//  After a safety override clears, the monitor holds fans at an elevated speed
//  for a minimum hold period, then ramps down only once temps are stable.
//  This breaks the oscillation loop where:
//    override fires → fans max → temps drop → override clears →
//    Apple slows fans → temps spike again → repeat
//
//  Temperature smoothing:
//  An exponential moving average (EMA, α=0.3) is applied to the temperature
//  used for fan control decisions. Raw temperature is still used for the 95°C
//  safety threshold. This prevents brief 2-second spikes from triggering
//  large fan reactions.
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
    case coolDown(targetTemp: Float)   // post-override hold
}

// MARK: - Thermal Monitor

public final class ThermalMonitor {
    private let fanControl: FanControl
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.thermalforge.monitor")

    public private(set) var activeProfile: FanProfile
    public private(set) var state: MonitorState = .idle
    public private(set) var latestStatus: ThermalStatus?

    // MARK: - Tick Timing

    private let tickInterval: Float
    private static let monitorCadence = 20   // 2s at 100ms ticks
    private static let uiUpdateCadence = 5   // 500ms at 100ms ticks
    private var tickCounter = 0

    // MARK: - Fan State

    private var lastAppliedRPMPercent: Float = 0
    private var fansCurrentlyRunning = false
    private var sustainedAboveCount = 0

    // MARK: - Temperature EMA

    /// Exponential moving average of temperature for smooth fan control.
    /// α=0.3 means ~3 ticks (300ms) to track a step change to 90%.
    /// Raw temperature is still used for the 95°C hard safety threshold.
    private var emaTemp: Float? = nil
    private static let emaAlpha: Float = 0.3

    // MARK: - Post-Override Cool-Down

    /// After a safety override clears, hold fans at coolDownHoldRPMPercent
    /// for at least coolDownHoldTicks ticks, and only release once smoothed
    /// temp has been below coolDownReleaseTemp for coolDownStableTicks ticks.
    ///
    /// At 100ms tick: 600 ticks = 60 seconds minimum hold.
    /// Release temp: 15°C below safety threshold (80°C) — well clear of the danger zone.
    /// Stable requirement: temp must stay below release temp for 20 ticks (2s).
    private static let coolDownHoldTicks    = 600   // 60s minimum hold
    private static let coolDownHoldRPMPct   = Float(0.65)  // ~65% of max RPM during hold
    private static let coolDownReleaseTemp  = Float(78.0)  // below this, allow ramp-down
    private static let coolDownStableTicks  = 20    // 2s stable before releasing
    private static let coolDownRampDownPerSec = Float(0.008) // very slow ~6% per second

    /// Ticks spent in cool-down state
    private var coolDownTicksElapsed = 0
    /// Consecutive ticks below coolDownReleaseTemp
    private var coolDownStableCount = 0
    /// RPM percent at entry into cool-down (inherited from override = 1.0)
    private var coolDownCurrentPct: Float = 1.0

    // MARK: - Smart Profile State

    private var tempHistory: [Float] = []

    // MARK: - Anomaly Detection

    private var anomalyHistory: [Float] = []
    private var isCalibrating = false

    // MARK: - Process Buffer

    private var processBuffer: [(timestamp: String, processes: String)] = []
    private let isoFormatter = ISO8601DateFormatter()

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

    public var onUpdate: ((ThermalStatus, FanProfile, MonitorState) -> Void)?
    public var onFanCommand: ((FanCommand) throws -> Void)?
    public var onAnomaly: ((String, Float, Float, Int) -> Void)?

    public init(fanControl: FanControl, profile: FanProfile = .silent) {
        self.fanControl = fanControl
        self.activeProfile = profile
        self.tickInterval = 0.1
    }

    // MARK: - Lifecycle

    public func start(interval: TimeInterval = 0.1) {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    public func switchProfile(_ profile: FanProfile) {
        queue.async { [self] in
            activeProfile = profile
            lastAppliedRPMPercent = 0
            fansCurrentlyRunning = false
            sustainedAboveCount = 0
            tickCounter = 0
            emaTemp = nil

            if profile.id == "smart" {
                tempHistory.removeAll()
                let loaded = CalibrationData.load()
                if let error = loaded?.validationError {
                    TFLogger.shared.error("Calibration data rejected on reload: \(error)")
                    calibration = nil
                } else {
                    calibration = loaded
                }
            }

            // Don't cancel an active cool-down when switching profiles —
            // the cool-down is a safety feature, not profile logic.
            if case .coolDown = state { } else {
                state = .idle
            }
        }
    }

    // MARK: - Polling

    private func tick() {
        guard let status = try? fanControl.status() else { return }
        latestStatus = status

        let cpuTemp = peakTemp(status, prefixes: ["TC", "Tp"])
        let gpuTemp = peakTemp(status, prefixes: ["TG", "Tg"])
        let rawTemp = max(cpuTemp, gpuTemp)

        // Update EMA — used for all fan control decisions except the hard safety threshold
        if let prev = emaTemp {
            emaTemp = Self.emaAlpha * rawTemp + (1 - Self.emaAlpha) * prev
        } else {
            emaTemp = rawTemp   // seed with first reading
        }
        let smoothTemp = emaTemp ?? rawTemp

        // Monitor cadence (every 2s)
        if tickCounter % Self.monitorCadence == 0 {
            monitorTick(status: status, maxTemp: rawTemp)
        }

        // ── Hard safety threshold uses RAW temperature ──
        // We never want smoothing to delay a 95°C response.
        if rawTemp >= FanProfile.safetyTempThreshold {
            if state != .safetyOverride {
                applyCommand(.setMax)
                fansCurrentlyRunning = true
                lastAppliedRPMPercent = 1.0
                TFLogger.shared.safety("Override triggered: \(String(format: "%.1f", rawTemp))°C — fans maxed")
            }
            state = .safetyOverride
            if tickCounter % Self.uiUpdateCadence == 0 {
                onUpdate?(status, activeProfile, state)
            }
            tickCounter += 1
            return
        }

        // ── Safety override cleared — enter cool-down ──
        if state == .safetyOverride
            && rawTemp < FanProfile.safetyTempThreshold - FanProfile.hysteresisDegrees
        {
            enterCoolDown()
        }

        // ── Cool-down state ──
        if case .coolDown = state {
            tickCoolDown(status: status, smoothTemp: smoothTemp)
            if tickCounter % Self.uiUpdateCadence == 0 {
                onUpdate?(status, activeProfile, state)
            }
            tickCounter += 1
            return
        }

        // ── Normal profile control uses SMOOTH temperature ──
        let startThreshold = activeProfile.curve.startTemp
        if smoothTemp >= startThreshold {
            sustainedAboveCount += 1
        } else {
            sustainedAboveCount = 0
        }

        if activeProfile.id == "smart" {
            tickSmart(status: status, peakTemp: smoothTemp)
        } else {
            tickCurve(status: status, peakTemp: smoothTemp)
        }

        if tickCounter % Self.uiUpdateCadence == 0 {
            onUpdate?(status, activeProfile, state)
        }
        tickCounter += 1
    }

    // MARK: - Cool-Down

    private func enterCoolDown() {
        coolDownTicksElapsed = 0
        coolDownStableCount = 0
        coolDownCurrentPct = lastAppliedRPMPercent  // inherit current RPM (usually 1.0)
        fansCurrentlyRunning = true
        state = .coolDown(targetTemp: Self.coolDownReleaseTemp)
        TFLogger.shared.safety(
            "Cool-down entered — holding fans at \(Int(coolDownCurrentPct * 100))% " +
            "for min \(Self.coolDownHoldTicks / 10)s, release below \(Int(Self.coolDownReleaseTemp))°C"
        )
    }

    private func tickCoolDown(status: ThermalStatus, smoothTemp: Float) {
        let maxRPM = status.fans.first.map { Float($0.maxRPM) } ?? 7826
        let minRPM = status.fans.first.map { Float($0.minRPM) } ?? 2317

        coolDownTicksElapsed += 1

        // During minimum hold: maintain hold RPM, no ramp-down yet
        if coolDownTicksElapsed < Self.coolDownHoldTicks {
            let holdPct = max(coolDownCurrentPct, Self.coolDownHoldRPMPct)
            if abs(holdPct - lastAppliedRPMPercent) > 0.002 {
                applyCommand(.setRPM(max(maxRPM * holdPct, minRPM)))
                lastAppliedRPMPercent = holdPct
            }
            return
        }

        // After minimum hold: check if temp is stable below release threshold
        if smoothTemp < Self.coolDownReleaseTemp {
            coolDownStableCount += 1
        } else {
            coolDownStableCount = 0
            // Temp is still high — maintain hold RPM, don't ramp down
            let holdPct = max(coolDownCurrentPct, Self.coolDownHoldRPMPct)
            if abs(holdPct - lastAppliedRPMPercent) > 0.002 {
                applyCommand(.setRPM(max(maxRPM * holdPct, minRPM)))
                lastAppliedRPMPercent = holdPct
            }
            return
        }

        // Stable below release temp: start slow ramp-down
        let rampDown = Self.coolDownRampDownPerSec * tickInterval
        let targetPct = max(lastAppliedRPMPercent - rampDown, 0)

        // Once we've ramped to zero (or below min), exit cool-down
        if targetPct <= minRPM / maxRPM {
            applyCommand(.resetAuto)
            lastAppliedRPMPercent = 0
            fansCurrentlyRunning = false
            state = .idle
            TFLogger.shared.safety(
                "Cool-down complete after \(coolDownTicksElapsed / 10)s — " +
                "temp stable at \(String(format: "%.1f", smoothTemp))°C, returned to profile"
            )
            return
        }

        if abs(targetPct - lastAppliedRPMPercent) > 0.001 {
            applyCommand(.setRPM(max(maxRPM * targetPct, minRPM)))
            lastAppliedRPMPercent = targetPct
            coolDownCurrentPct = targetPct
        }
    }

    // MARK: - Monitor Cadence (every 2 seconds)

    private func monitorTick(status: ThermalStatus, maxTemp: Float) {
        let currentProcs = captureTopProcesses()
        let ts = isoFormatter.string(from: Date())
        processBuffer.append((timestamp: ts, processes: currentProcs))
        if processBuffer.count > 15 { processBuffer.removeFirst() }

        if !isCalibrating {
            var spikeDetected = false

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
                    onAnomaly?("instant", prevTemp, maxTemp, 2)
                }
            }

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
                    onAnomaly?("sustained", oldest, maxTemp, 30)
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
            state = .idle
            TFLogger.shared.fan("Smart fans off: \(String(format: "%.1f", peakTemp))°C below \(Int(Self.smartStopTemp))°C")
            return
        }

        if peakTemp < Self.smartFloor && !fansCurrentlyRunning { return }
        if peakTemp >= Self.smartStopTemp && peakTemp < Self.smartFloor && !fansCurrentlyRunning { return }

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
            if rate > 0 { targetPct = min(targetPct + rate * 0.2, 1.0) }
        }

        if peakTemp > Self.smartCeiling { targetPct = 1.0 }
        targetPct = min(max(targetPct, 0), 1.0)
        if targetPct > 0 && targetPct < minPct { targetPct = minPct }

        let rampUp   = activeProfile.curve.rampUpPerSec * tickInterval
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
            state = .active(profileName: "Smart")
        } else if fansCurrentlyRunning {
            state = .active(profileName: "Smart")
        }
    }

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
                state = .idle
            }
            return
        }

        guard let rawTarget = curve.targetPercent(at: peakTemp, fansCurrentlyRunning: fansCurrentlyRunning) else {
            if fansCurrentlyRunning {
                applyCommand(.resetAuto)
                fansCurrentlyRunning = false
                lastAppliedRPMPercent = 0
                state = .idle
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

        let rampUp   = curve.rampUpPerSec * tickInterval
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
            state = .active(profileName: activeProfile.name)
        } else if fansCurrentlyRunning {
            state = .active(profileName: activeProfile.name)
        }
    }

    // MARK: - Process Capture

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
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { String(cString: $0) }
            }
            guard !name.isEmpty, name != "kernel_task" else { continue }
            let cpuPct = Double(proc.kp_proc.p_pctcpu) / 100.0
            if cpuPct > 0.1 { results.append((name, cpuPct)) }
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

// MARK: - Fan Commands

