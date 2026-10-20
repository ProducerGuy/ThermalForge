//
//  FanOffGate.swift
//  ThermalForge
//
//  Pure decision logic for the client monitor's fans-off transition.
//  Hardware-free so it unit-tests without SMC — ThermalMonitor performs the
//  actual fan commands; this type only decides.
//
//  One job: releasing fans to Apple's auto mode is CONFIRMED, not instant.
//  The peak sensor is a max over all CPU/GPU cores, and an idle core's
//  reading falls off a cliff (20-30°C within a tick or two) the moment its
//  workload ends. With stopTemp sitting at idle-core resting level the peak
//  oscillates across the threshold on a 100ms scale, and an instant release
//  hands the fans to Apple mid-ramp over and over — 2,182 releases in three
//  days of logs, fans slamming 3000+→1300 RPM every 3-7 seconds. Cold must
//  persist for FanProfile.stopSustainSeconds first; until then the fans HOLD
//  at minimum (the same treatment the hysteresis band gives), so a
//  dip-and-recover never stops the fans.
//

import Foundation

public struct FanOffGate {
    /// Release only after the peak has been at/below stopTemp this long
    /// (FanProfile.stopSustainSeconds).
    public let sustainSeconds: Float
    /// The monitor's thermal tick interval, converting seconds to ticks.
    public let tickInterval: Float

    private var coldTicks = 0

    /// - tickInterval: the monitor's tick (default 100ms).
    public init(sustainSeconds: Float = FanProfile.stopSustainSeconds,
                tickInterval: Float = 0.1) {
        self.sustainSeconds = sustainSeconds
        self.tickInterval = tickInterval
    }

    public enum Action: Equatable {
        /// Peak left the stop band — the curve drives again; the streak resets.
        case resume
        /// Cold, but not yet sustained — hold fans at minimum (hysteresis-band
        /// treatment). No mode change.
        case holdMinimum
        /// Sustained cold confirmed — hand the fans back to Apple now.
        case release
    }

    public mutating func evaluate(temp: Float, stopTemp: Float) -> Action {
        if temp <= stopTemp {
            coldTicks += 1
        } else {
            coldTicks = 0
        }

        if Float(coldTicks) * tickInterval >= sustainSeconds {
            coldTicks = 0
            return .release
        }
        return coldTicks > 0 ? .holdMinimum : .resume
    }
}
