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

            if profile.id == "max" {
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
