//
//  ProfileCommand.swift
//  ThermalForge
//
//  CLI for Custom Profiles (Custom Fan Curve, single- or dual-sensor, rq.md §16):
//  `thermalforge profile list|show|save|delete` — the "configuration API / file"
//  first-stage path the spec allows ahead of a full in-app editor.
//

import ArgumentParser
import Foundation
import ThermalForgeCore

struct ProfileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profile",
        abstract: "Manage Custom Profiles (single- or dual-sensor Custom Fan Curve)",
        subcommands: [
            ProfileListCommand.self,
            ProfileShowCommand.self,
            ProfileSaveCommand.self,
            ProfileDeleteCommand.self,
        ]
    )
}

// MARK: - Shared parsing

/// Parses "temp:percent,temp:percent,..." into single-axis curve points, e.g.
/// "50:0,55:20,60:35,65:55,70:75,75:100". Validation (sorted, no duplicates, 0-100,
/// finite) happens in `CustomCurve.init` — this only turns text into points.
func parseCurvePoints(_ raw: String) throws -> [FanCurvePoint] {
    try raw.split(separator: ",").map { pair in
        let parts = pair.split(separator: ":")
        guard parts.count == 2,
              let temperature = Float(parts[0].trimmingCharacters(in: .whitespaces)),
              let fanPercent = Float(parts[1].trimmingCharacters(in: .whitespaces))
        else {
            throw ValidationError("Invalid curve point '\(pair)'. Expected temp:percent, e.g. 50:0")
        }
        return FanCurvePoint(temperature: temperature, fanPercent: fanPercent)
    }
}

/// Parses "sensorA:sensorB:percent,..." into dual-sensor curve points, e.g.
/// "50:40:0,60:50:30,70:60:60,80:70:100" — the two readings are in `sensorA`/
/// `sensorB` order, e.g. --sensor-a cpu --sensor-b ambient means "cpu:ambient:percent".
/// Validation happens in `CustomCurve2D.init`.
func parseCurvePoints2D(_ raw: String) throws -> [FanCurvePoint2D] {
    try raw.split(separator: ",").map { triple in
        let parts = triple.split(separator: ":")
        guard parts.count == 3,
              let sensorAValue = Float(parts[0].trimmingCharacters(in: .whitespaces)),
              let sensorBValue = Float(parts[1].trimmingCharacters(in: .whitespaces)),
              let fanPercent = Float(parts[2].trimmingCharacters(in: .whitespaces))
        else {
            throw ValidationError("Invalid curve point '\(triple)'. Expected sensorA:sensorB:percent, e.g. 50:40:0")
        }
        return FanCurvePoint2D(sensorAValue: sensorAValue, sensorBValue: sensorBValue, fanPercent: fanPercent)
    }
}

/// Parses a `--sensor-a`/`--sensor-b` value ("cpu", "gpu", "ram", "ssd", "ambient").
func parseSensor(_ raw: String, option: String) throws -> Sensor {
    guard let sensor = Sensor(rawValue: raw.lowercased()) else {
        let options = Sensor.allCases.map(\.rawValue).joined(separator: ", ")
        throw ValidationError("Unknown sensor '\(raw)' for \(option). Options: \(options)")
    }
    return sensor
}

func describe(_ profile: FanProfile) -> String {
    var lines = ["\(profile.name) (\(profile.id))"]
    if let curve = profile.customCurve2D {
        lines.append("Curve (dual-sensor — \(curve.sensorA.displayName), \(curve.sensorB.displayName) → fan%):")
        for point in curve.points {
            lines.append("  \(curve.sensorA.displayName) \(Int(point.sensorAValue))°C, "
                + "\(curve.sensorB.displayName) \(Int(point.sensorBValue))°C → \(Int(point.fanPercent))%")
        }
    } else if let curve = profile.customCurve {
        lines.append("Curve:")
        for point in curve.points {
            lines.append("  \(Int(point.temperature))°C → \(Int(point.fanPercent))%")
        }
    } else {
        let c = profile.curve
        lines.append("Built-in curve: \(Int(c.stopTemp))–\(Int(c.startTemp))–\(Int(c.ceilingTemp))°C, "
            + "\(Int(c.maxRPMPercent * 100))% max, \(c.curveShape)")
    }
    lines.append("Ramp up/down: \(profile.curve.rampUpPerSec)/\(profile.curve.rampDownPerSec) per sec, "
        + "sustained trigger: \(Int(profile.curve.sustainedTriggerSec))s")
    return lines.joined(separator: "\n")
}

// MARK: - list

struct ProfileListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all profiles (built-in, Smart, and saved Custom Profiles)"
    )

    func run() throws {
        print("Built-in:")
        for p in FanProfile.builtIn { print("  \(p.id) — \(p.name)") }
        print("  smart — Smart")

        let custom = FanProfile.loadAll().filter { $0.customCurve != nil || $0.customCurve2D != nil }
        if custom.isEmpty {
            print("\nNo Custom Profiles saved. Create one with: thermalforge profile save <id> --curve ...")
        } else {
            print("\nCustom:")
            for p in custom {
                let kind = p.customCurve2D != nil ? " (dual-sensor)" : ""
                print("  \(p.id) — \(p.name)\(kind)")
            }
        }
    }
}

// MARK: - show

struct ProfileShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Print a profile's curve and governor settings"
    )

    @Argument(help: "Profile id")
    var id: String

    func run() throws {
        let profile = (FanProfile.loadAll() + [FanProfile.smart]).first { $0.id == id }
        guard let profile else {
            throw ValidationError("Unknown profile '\(id)'. Run 'thermalforge profile list' to see what's available.")
        }
        print(describe(profile))
    }
}

// MARK: - save (create or update)

struct ProfileSaveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "save",
        abstract: "Create or update a Custom Profile",
        discussion: """
            Single-sensor (one temperature axis):
              thermalforge profile save quiet --curve 45:0,80:40 --max-percent 0.4

            Dual-sensor (each point is sensorA:sensorB:fan%, jointly interpolated by
            distance in that 2D space — not gated by a separate condition). Choose any
            two of: cpu, gpu, ram, ssd, ambient (default cpu/gpu):
              thermalforge profile save dev --name Development \\
                --sensor-a cpu --sensor-b gpu \\
                --curve2d 50:40:0,60:50:30,70:60:60,80:70:100

            Exactly one of --curve / --curve2d is required. Saving with an id that
            already exists overwrites it (this is how you edit a Custom Profile from
            the CLI — there's no separate "edit" subcommand).
            """
    )

    @Argument(help: "Profile id — used as the filename and for --profile lookups")
    var id: String

    @Option(name: .long, help: "Display name (default: the id)")
    var name: String?

    @Option(name: .long, help: "Single-axis curve points as temp:percent pairs, ascending, e.g. 50:0,55:20,75:100")
    var curve: String?

    @Option(name: .long, help: "Dual-sensor curve points as sensorA:sensorB:percent triples, e.g. 50:40:0,80:70:100")
    var curve2d: String?

    @Option(name: .long, help: "First --curve2d sensor: cpu, gpu, ram, ssd, or ambient (default cpu)")
    var sensorA: String = "cpu"

    @Option(name: .long, help: "Second --curve2d sensor: cpu, gpu, ram, ssd, or ambient (default gpu)")
    var sensorB: String = "gpu"

    @Option(name: .long, help: "Max fan speed as a fraction 0...1 — the profile's safety ceiling (default 1.0)")
    var maxPercent: Float = 1.0

    @Option(name: .long, help: "Max fan speed increase per second, fraction of max RPM (default 0.05)")
    var rampUp: Float = 0.05

    @Option(name: .long, help: "Max fan speed decrease per second, fraction of max RPM (default 0.025)")
    var rampDown: Float = 0.025

    @Option(name: .long, help: "Seconds above the curve's start temp before fans engage (default 8)")
    var sustained: Float = 8

    func run() throws {
        let profile: FanProfile
        switch (curve, curve2d) {
        case (.some(let raw), nil):
            let customCurve = try CustomCurve(points: try parseCurvePoints(raw))
            profile = FanProfile.custom(
                id: id, name: name ?? id, customCurve: customCurve,
                rampUpPerSec: rampUp, rampDownPerSec: rampDown,
                sustainedTriggerSec: sustained, maxRPMPercent: maxPercent
            )
        case (nil, .some(let raw)):
            let a = try parseSensor(sensorA, option: "--sensor-a")
            let b = try parseSensor(sensorB, option: "--sensor-b")
            let customCurve2D = try CustomCurve2D(sensorA: a, sensorB: b, points: try parseCurvePoints2D(raw))
            profile = FanProfile.custom(
                id: id, name: name ?? id, customCurve2D: customCurve2D,
                rampUpPerSec: rampUp, rampDownPerSec: rampDown,
                sustainedTriggerSec: sustained, maxRPMPercent: maxPercent
            )
        case (nil, nil):
            throw ValidationError("Provide either --curve (single-axis) or --curve2d (dual-sensor).")
        case (.some, .some):
            throw ValidationError("Provide only one of --curve / --curve2d, not both.")
        }

        try profile.save()

        print("Saved Custom Profile:\n")
        print(describe(profile))
        print("\nActivate it with: thermalforge watch --profile \(profile.id)")
    }
}

// MARK: - delete

struct ProfileDeleteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete a saved Custom Profile"
    )

    @Argument(help: "Profile id")
    var id: String

    func run() throws {
        do {
            try FanProfile.delete(id: id)
        } catch {
            throw ValidationError("Couldn't delete '\(id)': \(error.localizedDescription)")
        }
        print("Deleted Custom Profile '\(id)'")
    }
}
