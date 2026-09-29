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

        /// Why this curve can't be used, or nil when it's sane. Applied to profiles loaded
        /// from disk so a hand-edited file can't drive the fans nonsensically.
        public var validationError: String? {
            if handsOff { return nil } // Silent controls nothing; its thresholds are inert

            // alwaysOn ignores temperature entirely and never hands the fans back to auto.
            // A built-in may choose that; a file on disk may not.
            if alwaysOn {
                return "alwaysOn holds the fans at a fixed speed regardless of temperature"
            }

            if stopTemp < 20 || stopTemp > 90 {
                return "stopTemp \(stopTemp)°C is out of range (20–90°C)"
            }
            // The project's stated rule: at least 5°C between stop and start, because
            // start/stop cycling is the #1 fan bearing wear factor.
            if startTemp - stopTemp < FanProfile.hysteresisDegrees {
                return "startTemp \(startTemp)°C needs at least "
                    + "\(Int(FanProfile.hysteresisDegrees))°C above stopTemp \(stopTemp)°C"
            }
            if startTemp >= FanProfile.safetyTempThreshold {
                return "startTemp \(startTemp)°C is at or above the "
                    + "\(Int(FanProfile.safetyTempThreshold))°C safety threshold"
            }
            // Instant-engage profiles have no proportional zone, so ceiling == start is the
            // shape they declare. For anything else it collapses the curve to a step.
            if instantEngage ? ceilingTemp < startTemp : ceilingTemp <= startTemp {
                return "ceilingTemp \(ceilingTemp)°C leaves no proportional zone above "
                    + "startTemp \(startTemp)°C"
            }
            // A ceiling past the safety threshold is unreachable — the 95°C override fires
            // first, so the profile would never reach its own cap.
            if ceilingTemp > FanProfile.safetyTempThreshold {
                return "ceilingTemp \(ceilingTemp)°C is above the "
                    + "\(Int(FanProfile.safetyTempThreshold))°C safety threshold"
            }
            if maxRPMPercent <= 0 || maxRPMPercent > 1 {
                return "maxRPMPercent \(maxRPMPercent) is out of range (0–1)"
            }
            if rampUpPerSec <= 0 || rampDownPerSec <= 0 {
                return "ramp rates must be positive"
            }
            // Generous upper bound: a long trigger is a legitimate choice for sustained
            // workloads where you want the fans to stay out of the way through a warm-up.
            if sustainedTriggerSec < 0 || sustainedTriggerSec > 300 {
                return "sustainedTriggerSec \(sustainedTriggerSec) is out of range (0–300s)"
            }
            return nil
        }

        /// Calculate the target fan speed percentage (0.0–1.0) for a given temperature.
        /// Returns nil if fans should be off (Apple auto).
        /// Returns 0.001 as a signal to keep fans at minimum RPM (hysteresis band).
        ///
        /// The curve runs from 0, so on hardware whose minimum RPM is a large fraction of
        /// its maximum the lower part of the band sits below what the fan can turn and the
        /// caller clamps it to minimum. See `ThermalMonitor.commandedPercent`.
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

    /// Resolve a persisted profile id to a known profile for launch restore. Searches the
    /// built-ins plus Smart (which is surfaced via its own button, so it isn't in
    /// `builtIn`). Returns Silent when the id is nil (nothing saved) or unrecognized (a
    /// profile removed or renamed in a later version), so a stale saved id never crashes.
    public static func selectable(id: String?) -> FanProfile {
        selectable(id: id, from: builtIn + [smart])
    }

    /// Resolve a persisted profile id against a caller-supplied list, so a custom profile
    /// the user selected is restored rather than silently falling back to Silent.
    public static func selectable(id: String?, from candidates: [FanProfile]) -> FanProfile {
        guard let id else { return .silent }
        return candidates.first { $0.id == id } ?? .silent
    }
}

// MARK: - Persistence

extension FanProfile {
    /// Ids that a file on disk may not claim, because the code branches on them by id.
    ///
    /// Smart is dispatched to its own adaptive path in ThermalMonitor, which reads only the
    /// ramp rates and sustained trigger — a custom `smart.json` would have most of its curve
    /// silently ignored, and would double up with Smart's own menu bar button. Silent is the
    /// app's initial and reset-to state, held as a static, so overriding it would leave the
    /// picker showing one profile while the monitor runs another.
    static let reservedProfileIDs: Set<String> = ["smart", "silent"]

    /// Where custom profiles live. Under `sudo` the effective user is root, whose home is
    /// `/var/root` — the CLI has to resolve the invoking user's home or it would look in
    /// the wrong place and find nothing, so SUDO_UID wins when it's set (same approach as
    /// `thermalforge install`).
    public static var defaultProfilesDirectory: URL {
        var home = FileManager.default.homeDirectoryForCurrentUser
        if geteuid() == 0,
           let sudoUID = ProcessInfo.processInfo.environment["SUDO_UID"],
           let uid = uid_t(sudoUID), uid != 0,
           let pw = getpwuid(uid),
           pw.pointee.pw_uid == uid, // the account must be the one SUDO_UID names
           let dir = pw.pointee.pw_dir
        {
            home = URL(fileURLWithPath: String(cString: dir))
        }
        return home.appendingPathComponent("Library/Application Support/ThermalForge/profiles")
    }

    public func save(to directory: URL = FanProfile.defaultProfilesDirectory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: directory.appendingPathComponent("\(id).json"))
    }

    /// Built-in profiles merged with any custom ones on disk. A file whose id matches a
    /// built-in replaces it; anything else is appended. Files that can't be read, can't be
    /// decoded, claim a reserved id, or describe an unusable curve are skipped and logged —
    /// a bad file must not take the fans with it.
    public static func loadAll(from directory: URL = FanProfile.defaultProfilesDirectory) -> [FanProfile] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else {
            return builtIn
        }

        var profiles = builtIn
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where file.pathExtension == "json" {
            let profile: FanProfile
            do {
                profile = try JSONDecoder().decode(FanProfile.self, from: Data(contentsOf: file))
            } catch {
                TFLogger.shared.error("Profile file \(file.lastPathComponent) unreadable: \(error)")
                continue
            }

            if reservedProfileIDs.contains(profile.id) {
                TFLogger.shared.error("Profile '\(profile.id)' rejected: that id is reserved")
                continue
            }
            // A hand-edited file that would drive the fans nonsensically is skipped
            // rather than offered, the same way calibration data is screened on load.
            if let error = profile.curve.validationError {
                TFLogger.shared.error("Profile '\(profile.id)' rejected: \(error)")
                continue
            }

            if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
                profiles[idx] = profile
            } else {
                profiles.append(profile)
            }
        }
        return orderedByCeiling(profiles)
    }

    /// Order profiles by how loud each is willing to get, so the picker escalates from
    /// quietest to loudest and a custom profile lands where a reader expects rather than
    /// tacked on after Max. The built-ins are already in this order (0, 0.60, 0.85, 1.0),
    /// so a machine with no custom profiles sees exactly the list it saw before.
    /// Ties keep insertion order, which puts a built-in ahead of a custom profile.
    static func orderedByCeiling(_ profiles: [FanProfile]) -> [FanProfile] {
        profiles.enumerated().sorted { lhs, rhs in
            let a = lhs.element.curve.maxRPMPercent
            let b = rhs.element.curve.maxRPMPercent
            return a == b ? lhs.offset < rhs.offset : a < b
        }.map(\.element)
    }
}

// MARK: - Safety

extension FanProfile {
    /// Hard safety threshold — overrides any profile
    public static let safetyTempThreshold: Float = 95.0
    /// Hysteresis deadband to prevent oscillation
    public static let hysteresisDegrees: Float = 5.0
}
