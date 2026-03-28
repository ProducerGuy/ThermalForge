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

    // Smart profile state
    private var tempHistory: [Float] = []
    private var lastSmartRPMPercent: Float = 0
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

    /// Update the active profile. Does NOT execute fan commands —
    /// the caller is responsible for immediate actions (Max/Auto).
    /// Threshold-based commands are handled by tick().
    public func switchProfile(_ profile: FanProfile) {
        queue.async { [self] in
            activeProfile = profile

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
                state = .idle
            } else if profile.id == "max" {
                state = .active(profileName: "Max")
            } else if profile.id == "silent" || profile.fanBehavior.mode == .auto {
                state = .idle
            } else {
                // Balanced/Performance — let tick() evaluate thresholds
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

        // Safety override: any sensor > 95°C
        if maxTemp >= FanProfile.safetyTempThreshold {
            if state != .safetyOverride {
                applyCommand(.setMax)
                state = .safetyOverride
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

        // Smart profile: graduated curve with rate-of-change awareness
        if activeProfile.id == "smart" {
            tickSmart(status: status, peakTemp: maxTemp)
            onUpdate?(status, activeProfile, state)
            return
        }

        // Skip trigger evaluation for manual-only profiles
        if activeProfile.id == "silent" || activeProfile.id == "max" {
            onUpdate?(status, activeProfile, state)
            return
        }

        // Evaluate profile triggers
        let triggered = isTriggered(
            profile: activeProfile, cpuTemp: cpuTemp, gpuTemp: gpuTemp
        )

        let currentlyActive: Bool
        if case .active = state { currentlyActive = true } else { currentlyActive = false }

        if triggered && !currentlyActive {
            // Threshold crossed — ramp fans
            let maxRPM = status.fans.first.map { Float($0.maxRPM) } ?? 7826
            let targetRPM = maxRPM * activeProfile.fanBehavior.rpmPercent
            applyCommand(.setRPM(targetRPM))
            state = .active(profileName: activeProfile.name)
        } else if !triggered && currentlyActive {
            // Below threshold with hysteresis — return to auto
            let belowHysteresis = isBelowHysteresis(
                profile: activeProfile, cpuTemp: cpuTemp, gpuTemp: gpuTemp
            )
            if belowHysteresis {
                applyCommand(.resetAuto)
                state = .idle
            }
        }

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
                // If this fan speed held full load (1.0), it can handle anything
                if m.maxSustainableLoad ?? 1.0 >= 1.0 {
                    basePct = m.rpmPercent
                    break
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
            let targetRPM = maxRPM * targetPct
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

    // MARK: - Trigger Evaluation

    private func isTriggered(profile: FanProfile, cpuTemp: Float, gpuTemp: Float) -> Bool {
        if let threshold = profile.triggers.cpuTemp, cpuTemp >= threshold {
            return true
        }
        if let threshold = profile.triggers.gpuTemp, gpuTemp >= threshold {
            return true
        }
        if let threshold = profile.triggers.memPressure, memoryPressure() >= threshold {
            return true
        }
        return false
    }

    private func isBelowHysteresis(profile: FanProfile, cpuTemp: Float, gpuTemp: Float) -> Bool {
        let deadband = FanProfile.hysteresisDegrees
        if let threshold = profile.triggers.cpuTemp, cpuTemp > threshold - deadband {
            return false
        }
        if let threshold = profile.triggers.gpuTemp, gpuTemp > threshold - deadband {
            return false
        }
        return true
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
            // Log but don't crash — monitor should keep running
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
