//
//  Profile.swift
//  ThermalForge
//
//  Fan control profiles with proportional temperature curves.
//
//  Each profile defines a curve that maps temperature to fan speed.
//  Based on Apple fan hardware research:
//  - 0 to minimum RPM is binary (hardware limitation)
//  - Above minimum, proportional ramping
//  - Start/stop cycles are the #1 fan bearing wear factor
//  - At least 5°C hysteresis between start and stop thresholds
//

import Foundation

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

        /// Above this temperature, fans start at minimum RPM and begin ramping.
        public let startTemp: Float

        /// Temperature at which fan speed reaches maxRPMPercent.
        public let ceilingTemp: Float

        /// Maximum fan speed as fraction of max RPM (0.0–1.0).
        /// Fan speed scales proportionally between startTemp and ceilingTemp.
        public let maxRPMPercent: Float

        /// If true, this profile doesn't control fans — stays in Apple auto mode.
        /// Only intervenes at ceilingTemp to ensure Apple is handling it.
        public let handsOff: Bool

        /// If true, fans are always at maxRPMPercent regardless of temperature.
        public let alwaysOn: Bool

        public init(stopTemp: Float = 50, startTemp: Float = 55, ceilingTemp: Float = 70,
                    maxRPMPercent: Float = 0.6, handsOff: Bool = false, alwaysOn: Bool = false) {
            self.stopTemp = stopTemp
            self.startTemp = startTemp
            self.ceilingTemp = ceilingTemp
            self.maxRPMPercent = maxRPMPercent
            self.handsOff = handsOff
            self.alwaysOn = alwaysOn
        }

        /// Calculate the target fan speed percentage (0.0–1.0) for a given temperature.
        /// Returns nil if fans should be off (Apple auto).
        /// Returns the proportional value between minRPM and maxRPMPercent if in the curve zone.
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

            // Above start: proportional curve
            if temp >= startTemp {
                if temp >= ceilingTemp { return maxRPMPercent }
                let position = (temp - startTemp) / (ceilingTemp - startTemp)
                return position * maxRPMPercent
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

    /// Balanced: gentle proportional ramp for everyday use.
    /// Fans off below 50°C. Ramp 55–70°C up to 60% max RPM.
    /// Sustained trigger: only engages after 8 seconds above 55°C.
    public static let balanced = FanProfile(
        id: "balanced",
        name: "Balanced",
        curve: Curve(stopTemp: 50, startTemp: 55, ceilingTemp: 70,
                     maxRPMPercent: 0.60)
    )

    /// Performance: steeper curve, targets lower ceiling.
    /// Fans off below 50°C. Ramp 55–65°C up to 85% max RPM.
    public static let performance = FanProfile(
        id: "performance",
        name: "Performance",
        curve: Curve(stopTemp: 50, startTemp: 55, ceilingTemp: 65,
                     maxRPMPercent: 0.85)
    )

    /// Max: ramps to 100% with governor. Not always-on — off below 50°C.
    /// Starts at 55°C, reaches 100% at 65°C ceiling.
    public static let max = FanProfile(
        id: "max",
        name: "Max",
        curve: Curve(stopTemp: 50, startTemp: 55, ceilingTemp: 65,
                     maxRPMPercent: 1.0)
    )

    /// Smart: proactive adaptive curve with rate-of-change awareness.
    /// Starts 2°C earlier (53°C) to get ahead of rising temps.
    /// Uses calibration data when available. 53–85°C range, up to 100%.
    public static let smart = FanProfile(
        id: "smart",
        name: "Smart",
        curve: Curve(stopTemp: 50, startTemp: 53, ceilingTemp: 85,
                     maxRPMPercent: 1.0)
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

