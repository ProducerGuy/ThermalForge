//
//  Profile.swift
//  ThermalForge
//
//  Fan control profiles with proportional temperature curves.
//
//  Each profile defines a curve that maps temperature to fan speed,
//  along with per-profile ramp rates, sustained triggers, and curve shapes.
//
//  Based on Apple fan hardware research:
//  - 0 to minimum RPM is binary (hardware limitation)
//  - Above minimum, proportional ramping with configurable curve shape
//  - Start/stop cycles are the #1 fan bearing wear factor
//  - At least 5°C hysteresis between start and stop thresholds
//  - Ramp governors are acoustic comfort, not bearing protection
//

import Foundation

// MARK: - Curve Shape

/// How the profile maps temperature position to fan speed in the proportional zone.
public enum CurveShape: String, Codable, Equatable {
    /// pos * max — direct proportional response
    case linear
    /// pos² * max — quiet start, accelerates with heat
    case easeIn
    /// √pos * max — fast initial response, levels off
    case easeOut
    /// pos²(3-2pos) * max — smooth at both ends
    case sCurve
}

// MARK: - Profile Model

public struct FanProfile: Codable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let curve: Curve

    /// Defines how the profile maps temperature to fan speed.
    public struct Curve: Codable, Equatable {
        /// Below this temperature, fans turn off (return to Apple auto).
        /// Must be at least 5°C below startTemp for hysteresis.
        public let stopTemp: Float

        /// Above this temperature, fans engage (after sustained trigger is met).
        public let startTemp: Float

        /// Temperature at which fan speed reaches maxRPMPercent.
        /// Ignored when instantEngage is true (binary on/off).
        public let ceilingTemp: Float

        /// Maximum fan speed as fraction of max RPM (0.0–1.0).
        public let maxRPMPercent: Float

        /// If true, this profile doesn't control fans — stays in Apple auto mode.
        public let handsOff: Bool

        /// If true, fans are always at maxRPMPercent regardless of temperature.
        public let alwaysOn: Bool

        /// How temperature maps to fan speed in the proportional zone.
        public let curveShape: CurveShape

        /// Max fan speed increase per second (fraction of max RPM per second).
        /// Ignored when instantEngage is true.
        public let rampUpPerSec: Float

        /// Max fan speed decrease per second (fraction of max RPM per second).
        public let rampDownPerSec: Float

        /// Seconds of sustained temperature above startTemp before fans engage.
        /// Filters transient spikes that resolve on their own.
        public let sustainedTriggerSec: Float

        /// If true, skip ramp-up governor — jump directly to maxRPMPercent.
        /// Ramp-down governor still applies for smooth deceleration.
        public let instantEngage: Bool

        public init(stopTemp: Float = 50, startTemp: Float = 55, ceilingTemp: Float = 70,
                    maxRPMPercent: Float = 0.6, handsOff: Bool = false, alwaysOn: Bool = false,
                    curveShape: CurveShape = .linear, rampUpPerSec: Float = 0.05,
                    rampDownPerSec: Float = 0.025, sustainedTriggerSec: Float = 8,
                    instantEngage: Bool = false) {
            self.stopTemp = stopTemp
            self.startTemp = startTemp
            self.ceilingTemp = ceilingTemp
            self.maxRPMPercent = maxRPMPercent
            self.handsOff = handsOff
            self.alwaysOn = alwaysOn
            self.curveShape = curveShape
            self.rampUpPerSec = rampUpPerSec
            self.rampDownPerSec = rampDownPerSec
            self.sustainedTriggerSec = sustainedTriggerSec
            self.instantEngage = instantEngage
        }

        /// Calculate the target fan speed percentage (0.0–1.0) for a given temperature.
        /// Returns nil if fans should be off (Apple auto).
        /// Returns 0.001 as a signal to keep fans at minimum RPM (hysteresis band).
        public func targetPercent(at temp: Float, fansCurrentlyRunning: Bool) -> Float? {
            // Always-on profiles ignore temperature
            if alwaysOn { return maxRPMPercent }

            // Hands-off profiles don't control fans
            if handsOff { return nil }

            // Below stop threshold and fans not running: stay off
            if temp <= stopTemp && !fansCurrentlyRunning { return nil }

            // In hysteresis band (between stop and start): maintain current state
            if temp > stopTemp && temp < startTemp {
                return fansCurrentlyRunning ? 0.001 : nil // 0.001 signals "keep at minimum"
            }

            // Below stop threshold but fans are running: turn off
            if temp <= stopTemp && fansCurrentlyRunning { return nil }

            // Above start: apply curve shape
            if temp >= startTemp {
                if temp >= ceilingTemp { return maxRPMPercent }

                // Instant engage profiles jump directly to max (no proportional curve up)
                if instantEngage { return maxRPMPercent }

                let position = (temp - startTemp) / (ceilingTemp - startTemp)
                let shaped: Float
                switch curveShape {
                case .linear:
                    shaped = position
                case .easeIn:
                    shaped = position * position
                case .easeOut:
                    shaped = sqrt(position)
                case .sCurve:
                    shaped = position * position * (3 - 2 * position)
                }
                return shaped * maxRPMPercent
            }

            return nil
        }
    }

    public init(id: String, name: String, curve: Curve) {
        self.id = id
        self.name = name
        self.curve = curve
    }

    // Legacy support — old profiles used triggers/fanBehavior
    public struct Triggers: Codable, Equatable {
        public let cpuTemp: Float?
        public let gpuTemp: Float?
        public let memPressure: Float?
        public init(cpuTemp: Float? = nil, gpuTemp: Float? = nil, memPressure: Float? = nil) {
            self.cpuTemp = cpuTemp; self.gpuTemp = gpuTemp; self.memPressure = memPressure
        }
    }
    public struct FanBehavior: Codable, Equatable {
        public let mode: Mode
        public let rpmPercent: Float
        public enum Mode: String, Codable, Equatable { case auto, manual }
        public init(mode: Mode, rpmPercent: Float) { self.mode = mode; self.rpmPercent = rpmPercent }
    }
}

// MARK: - Built-in Profiles

extension FanProfile {
    /// Silent (Apple Default): hands-off, let Apple control fans. ThermalForge monitors only.
    public static let silent = FanProfile(
        id: "silent",
        name: "Silent (Apple Default)",
        curve: Curve(stopTemp: 50, startTemp: 55, ceilingTemp: 55,
                     maxRPMPercent: 0, handsOff: true)
    )

    /// Balanced: gentle ease-in curve for everyday use.
    /// Quiet at low temps (pos²), ramps harder as heat builds.
    /// 8-second sustained trigger filters all transients.
    public static let balanced = FanProfile(
        id: "balanced",
        name: "Balanced",
        curve: Curve(stopTemp: 50, startTemp: 55, ceilingTemp: 70,
                     maxRPMPercent: 0.60, curveShape: .easeIn,
                     rampUpPerSec: 0.05, rampDownPerSec: 0.025,
                     sustainedTriggerSec: 8)
    )

    /// Performance: linear curve, fast response. Thermals over noise.
    /// 4-second sustained trigger, 2× ramp-up speed vs Balanced.
    public static let performance = FanProfile(
        id: "performance",
        name: "Performance",
        curve: Curve(stopTemp: 50, startTemp: 55, ceilingTemp: 65,
                     maxRPMPercent: 0.85, curveShape: .linear,
                     rampUpPerSec: 0.10, rampDownPerSec: 0.04,
                     sustainedTriggerSec: 4)
    )

    /// Max: attack dog. Instant 100% after 5-second sustained trigger at 65°C.
    /// They spike, we spike. Ramp-down governor lets temps stabilize before backing off.
    public static let max = FanProfile(
        id: "max",
        name: "Max",
        curve: Curve(stopTemp: 50, startTemp: 65, ceilingTemp: 65,
                     maxRPMPercent: 1.0, curveShape: .linear,
                     rampUpPerSec: 1.0, rampDownPerSec: 0.025,
                     sustainedTriggerSec: 5, instantEngage: true)
    )

    /// Smart: proactive S-curve with rate-of-change awareness.
    /// Starts 2°C earlier (53°C) to get ahead of rising temps.
    /// Uses calibration data when available. 6-second sustained trigger.
    public static let smart = FanProfile(
        id: "smart",
        name: "Smart",
        curve: Curve(stopTemp: 50, startTemp: 53, ceilingTemp: 85,
                     maxRPMPercent: 1.0, curveShape: .sCurve,
                     rampUpPerSec: 0.05, rampDownPerSec: 0.025,
                     sustainedTriggerSec: 6)
    )

    public static let builtIn: [FanProfile] = [silent, balanced, performance, max]
}

// MARK: - Persistence

extension FanProfile {
    private static var profilesDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ThermalForge/profiles")
    }

    public func save() throws {
        let dir = Self.profilesDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: dir.appendingPathComponent("\(id).json"))
    }

    public static func loadAll() -> [FanProfile] {
        let dir = profilesDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else {
            return builtIn
        }

        var profiles = builtIn
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let profile = try? JSONDecoder().decode(FanProfile.self, from: data)
            {
                if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
                    profiles[idx] = profile
                } else {
                    profiles.append(profile)
                }
            }
        }
        return profiles
    }
}

// MARK: - Safety

extension FanProfile {
    /// Hard safety threshold — overrides any profile
    public static let safetyTempThreshold: Float = 95.0
    /// Hysteresis deadband to prevent oscillation
    public static let hysteresisDegrees: Float = 5.0
}
