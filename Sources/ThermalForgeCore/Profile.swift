//
//  Profile.swift
//  ThermalForge
//
//  Fan control profiles with temperature-based triggers.
//

import Foundation

// MARK: - Profile Model

public struct FanProfile: Codable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let triggers: Triggers
    public let fanBehavior: FanBehavior

    public struct Triggers: Codable, Equatable {
        /// CPU temperature threshold in °C (nil = manual only)
        public let cpuTemp: Float?
        /// GPU temperature threshold in °C
        public let gpuTemp: Float?
        /// Memory pressure percentage 0–100
        public let memPressure: Float?

        public init(cpuTemp: Float? = nil, gpuTemp: Float? = nil, memPressure: Float? = nil) {
            self.cpuTemp = cpuTemp
            self.gpuTemp = gpuTemp
            self.memPressure = memPressure
        }
    }

    public struct FanBehavior: Codable, Equatable {
        public let mode: Mode
        /// Fan speed as fraction of max RPM (0.0–1.0)
        public let rpmPercent: Float

        public enum Mode: String, Codable, Equatable {
            case auto
            case manual
        }

        public init(mode: Mode, rpmPercent: Float) {
            self.mode = mode
            self.rpmPercent = rpmPercent
        }
    }

    public init(id: String, name: String, triggers: Triggers, fanBehavior: FanBehavior) {
        self.id = id
        self.name = name
        self.triggers = triggers
        self.fanBehavior = fanBehavior
    }
}

// MARK: - Built-in Profiles

extension FanProfile {
    public static let silent = FanProfile(
        id: "silent",
        name: "Silent",
        triggers: Triggers(),
        fanBehavior: FanBehavior(mode: .auto, rpmPercent: 0)
    )

    public static let balanced = FanProfile(
        id: "balanced",
        name: "Balanced",
        triggers: Triggers(cpuTemp: 70, gpuTemp: 65),
        fanBehavior: FanBehavior(mode: .manual, rpmPercent: 0.60)
    )

    public static let performance = FanProfile(
        id: "performance",
        name: "Performance",
        triggers: Triggers(cpuTemp: 80, gpuTemp: 75, memPressure: 70),
        fanBehavior: FanBehavior(mode: .manual, rpmPercent: 0.85)
    )

    public static let max = FanProfile(
        id: "max",
        name: "Max",
        triggers: Triggers(),
        fanBehavior: FanBehavior(mode: .manual, rpmPercent: 1.0)
    )

    public static let smart = FanProfile(
        id: "smart",
        name: "Smart",
        triggers: Triggers(),
        fanBehavior: FanBehavior(mode: .manual, rpmPercent: 0)
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
                // Replace built-in if same ID, otherwise append
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
