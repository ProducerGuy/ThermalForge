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

public struct FanProfile: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let curve: Curve

    /// When set, a Custom Profile's user-defined temperature → fan% points replace
    /// `curve`'s shape function (linear/easeIn/easeOut/sCurve) above `curve.startTemp`;
    /// `curve`'s stopTemp/startTemp hysteresis, maxRPMPercent ceiling, ramp rates, and
    /// sustained trigger are reused unchanged — see `Curve.targetPercent(customCurve:)`.
    /// nil for every built-in profile. Mutually exclusive with `customCurve2D` — a
    /// profile uses one or the other, never both (see `FanProfile.custom(...)`).
    public let customCurve: CustomCurve?

    /// When set, a Custom Profile's fan% is shaped by two sensors' readings jointly —
    /// each point is (sensorA reading, sensorB reading) → fan%, rather than one
    /// temperature axis. The two sensors are the curve's own `sensorA`/`sensorB` (any
    /// of `Sensor`'s cases, not just CPU/GPU). Same hysteresis/ramp/ceiling reuse as
    /// `customCurve`; see `Curve.targetPercent(customCurve2D:)`. nil for every
    /// built-in profile.
    public let customCurve2D: CustomCurve2D?

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
        ///
        /// `temp` still drives the stopTemp/startTemp on/off hysteresis below — that
        /// stays a single scalar (the same CPU+GPU peak every profile uses) regardless
        /// of curve type, so a Custom Curve (1D or 2D) can't bypass the existing
        /// governor (rq.md §20). Only the in-zone shape changes:
        /// - customCurve: a Custom Profile's user-defined temperature → fan% points,
        ///   replacing the shape function above `startTemp`.
        /// - customCurve2D: a dual-sensor Custom Profile's (sensorA, sensorB) → fan%
        ///   points — takes priority over `customCurve` if somehow both are passed.
        /// Both nil for every built-in profile, identical to the original behavior.
        public func targetPercent(
            at temp: Float, fansCurrentlyRunning: Bool,
            customCurve: CustomCurve? = nil,
            customCurve2D: (curve: CustomCurve2D, sensorAValue: Float, sensorBValue: Float)? = nil
        ) -> Float? {
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
                // Custom Curves are still capped by maxRPMPercent (the profile's safety
                // ceiling) — ceilingTemp/instantEngage/curveShape don't apply, since the
                // custom points define the whole shape.
                if let customCurve2D {
                    let percent = customCurve2D.curve.evaluate(
                        sensorAValue: customCurve2D.sensorAValue, sensorBValue: customCurve2D.sensorBValue
                    ) / 100.0
                    return min(percent, maxRPMPercent)
                }
                if let customCurve {
                    let percent = customCurve.evaluate(at: temp) / 100.0
                    return min(percent, maxRPMPercent)
                }

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

    public init(
        id: String, name: String, curve: Curve,
        customCurve: CustomCurve? = nil, customCurve2D: CustomCurve2D? = nil
    ) {
        self.id = id
        self.name = name
        self.curve = curve
        self.customCurve = customCurve
        self.customCurve2D = customCurve2D
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

// MARK: - Codable

extension FanProfile: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, curve, customCurve, customCurve2D
    }

    /// Manual (not synthesized) so a profile JSON saved before `customCurve`/
    /// `customCurve2D` existed still decodes — missing keys fall back to "no Custom
    /// Curve" instead of failing `loadAll()`. Also tolerates a profile JSON saved by
    /// the earlier sensor-condition design (extra `sensorConditions`/
    /// `conditionOperator` keys are simply ignored, not an error).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        curve = try container.decode(Curve.self, forKey: .curve)
        customCurve = try container.decodeIfPresent(CustomCurve.self, forKey: .customCurve)
        customCurve2D = try container.decodeIfPresent(CustomCurve2D.self, forKey: .customCurve2D)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(curve, forKey: .curve)
        try container.encodeIfPresent(customCurve, forKey: .customCurve)
        try container.encodeIfPresent(customCurve2D, forKey: .customCurve2D)
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
        guard let id else { return .silent }
        if let known = (builtIn + [smart]).first(where: { $0.id == id }) { return known }
        // Not a built-in — check persisted Custom Profiles before falling back.
        return loadAll().first { $0.id == id } ?? .silent
    }
}

// MARK: - Custom Profile

extension FanProfile {
    /// Builds a Custom Profile from a single-axis `CustomCurve`. The underlying
    /// `Curve` — stop/start hysteresis, ramp rates, sustained trigger, and the
    /// maxRPMPercent safety ceiling — is derived from the custom curve's own
    /// temperature bounds, so the existing governor and hysteresis keep working
    /// unchanged; tune them via the trailing parameters like any other profile.
    /// `ceilingTemp`/`instantEngage`/`curveShape` are unused once a custom curve is
    /// set (see `Curve.targetPercent(customCurve:)`).
    public static func custom(
        id: String,
        name: String,
        customCurve: CustomCurve,
        rampUpPerSec: Float = 0.05,
        rampDownPerSec: Float = 0.025,
        sustainedTriggerSec: Float = 8,
        maxRPMPercent: Float = 1.0
    ) -> FanProfile {
        let startTemp = customCurve.points[0].temperature
        let curve = Curve(
            stopTemp: startTemp - hysteresisDegrees,
            startTemp: startTemp,
            ceilingTemp: customCurve.points[customCurve.points.count - 1].temperature,
            maxRPMPercent: maxRPMPercent,
            rampUpPerSec: rampUpPerSec,
            rampDownPerSec: rampDownPerSec,
            sustainedTriggerSec: sustainedTriggerSec
        )
        return FanProfile(id: id, name: name, curve: curve, customCurve: customCurve)
    }

    /// Builds a dual-sensor Custom Profile from a `CustomCurve2D` — each point is
    /// (sensorA reading, sensorB reading) → fan%, jointly shaped by both of the
    /// curve's chosen sensors rather than one temperature axis. `startTemp` (and so
    /// `stopTemp`, 5°C below it) defaults to the lowest "peak" among the curve's own
    /// points — `max(sensorAValue, sensorBValue)` per point, then the minimum of
    /// those — so hysteresis engages roughly where the curve's own data begins,
    /// without the caller having to repeat that number. Everything else mirrors the
    /// single-axis `custom(customCurve:)` overload above.
    public static func custom(
        id: String,
        name: String,
        customCurve2D: CustomCurve2D,
        rampUpPerSec: Float = 0.05,
        rampDownPerSec: Float = 0.025,
        sustainedTriggerSec: Float = 8,
        maxRPMPercent: Float = 1.0
    ) -> FanProfile {
        // Swift.max: unqualified `max` here would resolve to the `FanProfile.max`
        // static property (the built-in "Max" profile) instead of the global function.
        let startTemp = customCurve2D.points.map { Swift.max($0.sensorAValue, $0.sensorBValue) }.min() ?? 50
        let curve = Curve(
            stopTemp: startTemp - hysteresisDegrees,
            startTemp: startTemp,
            ceilingTemp: startTemp + 1, // unused once customCurve2D is set
            maxRPMPercent: maxRPMPercent,
            rampUpPerSec: rampUpPerSec,
            rampDownPerSec: rampDownPerSec,
            sustainedTriggerSec: sustainedTriggerSec
        )
        return FanProfile(id: id, name: name, curve: curve, customCurve2D: customCurve2D)
    }
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

    /// Removes a saved Custom Profile. Throws (a standard "no such file" error) if
    /// nothing was saved under `id` — including every built-in id, which never has a
    /// file here unless something else deliberately overrode it via `save()`.
    public static func delete(id: String) throws {
        try FileManager.default.removeItem(at: profilesDirectory.appendingPathComponent("\(id).json"))
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
