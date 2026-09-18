//
//  ProfileCommand.swift
//  ThermalForge
//
//  CLI for Custom Profiles (Custom Fan Curve + Dual Sensor Condition, rq.md §16):
//  `thermalforge profile list|show|save|delete` — the "configuration API / file"
//  first-stage path the spec allows ahead of a full in-app editor.
//

import ArgumentParser
import Foundation
import ThermalForgeCore

struct ProfileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profile",
        abstract: "Manage Custom Profiles (Custom Fan Curve + Dual Sensor Condition)",
        subcommands: [
            ProfileListCommand.self,
            ProfileShowCommand.self,
            ProfileSaveCommand.self,
            ProfileDeleteCommand.self,
        ]
    )
}

// MARK: - Shared parsing

/// Parses "temp:percent,temp:percent,..." into curve points, e.g.
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

/// Parses a single condition string like "cpu>=65" or "gpu < 60" into a
/// `SensorCondition`. Checks the two-character operators (>=, <=) before the
/// one-character ones so ">=" isn't misread as ">" followed by a stray "=".
func parseCondition(_ raw: String) throws -> SensorCondition {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    let operators: [(String, ComparisonOperator)] = [
        (">=", .greaterThanOrEqual), ("<=", .lessThanOrEqual),
        (">", .greaterThan), ("<", .lessThan),
    ]
    for (token, comparison) in operators {
        guard let range = trimmed.range(of: token) else { continue }
        let sensorText = trimmed[trimmed.startIndex..<range.lowerBound]
            .trimmingCharacters(in: .whitespaces).lowercased()
        let thresholdText = trimmed[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard let sensor = Sensor(rawValue: sensorText) else {
            throw ValidationError("Unknown sensor '\(sensorText)' in condition '\(raw)'. Options: cpu, gpu")
        }
        guard let threshold = Float(thresholdText) else {
            throw ValidationError("Invalid threshold in condition '\(raw)'")
        }
        return SensorCondition(sensor: sensor, comparison: comparison, threshold: threshold)
    }
    throw ValidationError("Invalid condition '\(raw)'. Expected e.g. cpu>=65")
}

func parseConditionOperator(_ raw: String?) throws -> ConditionOperator? {
    switch raw?.lowercased() {
    case nil: return nil
    case "and": return .and
    case "or": return .or
    default: throw ValidationError("--condition-operator must be 'and' or 'or'")
    }
}

func describe(_ profile: FanProfile) -> String {
    var lines = ["\(profile.name) (\(profile.id))"]
    if let curve = profile.customCurve {
        lines.append("Curve:")
        for point in curve.points {
            lines.append("  \(Int(point.temperature))°C → \(Int(point.fanPercent))%")
        }
    } else {
        let c = profile.curve
        lines.append("Built-in curve: \(Int(c.stopTemp))–\(Int(c.startTemp))–\(Int(c.ceilingTemp))°C, "
            + "\(Int(c.maxRPMPercent * 100))% max, \(c.curveShape)")
    }
    if !profile.sensorConditions.isEmpty {
        let joiner = profile.conditionOperator.map { " \($0.rawValue.uppercased()) " } ?? ", "
        let clauses = profile.sensorConditions.map {
            "\($0.sensor.displayName) \($0.comparison.rawValue) \(Int($0.threshold))°C"
        }
        lines.append("Conditions: " + clauses.joined(separator: joiner))
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

        let custom = FanProfile.loadAll().filter { $0.customCurve != nil }
        if custom.isEmpty {
            print("\nNo Custom Profiles saved. Create one with: thermalforge profile save <id> --curve ...")
        } else {
            print("\nCustom:")
            for p in custom { print("  \(p.id) — \(p.name)") }
        }
    }
}

// MARK: - show

struct ProfileShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Print a profile's curve, conditions, and governor settings"
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
            Examples:
              thermalforge profile save dev --name Development \\
                --curve 50:0,55:20,60:35,65:55,70:75,75:100 \\
                --condition "cpu>=65" --condition "gpu>=60" --condition-operator or

              thermalforge profile save quiet --curve 45:0,80:40 --max-percent 0.4

            Saving with an id that already exists overwrites it (this is how you edit
            a Custom Profile from the CLI — there's no separate "edit" subcommand).
            """
    )

    @Argument(help: "Profile id — used as the filename and for --profile lookups")
    var id: String

    @Option(name: .long, help: "Display name (default: the id)")
    var name: String?

    @Option(name: .long, help: "Curve points as temp:percent pairs, ascending, e.g. 50:0,55:20,75:100")
    var curve: String

    @Option(name: .long, help: "Sensor condition, e.g. 'cpu>=65'. Repeat to add a second (max 2).")
    var condition: [String] = []

    @Option(name: .long, help: "How two conditions combine: and, or. Required iff there are 2 conditions.")
    var conditionOperator: String?

    @Option(name: .long, help: "Max fan speed as a fraction 0...1 — the profile's safety ceiling (default 1.0)")
    var maxPercent: Float = 1.0

    @Option(name: .long, help: "Max fan speed increase per second, fraction of max RPM (default 0.05)")
    var rampUp: Float = 0.05

    @Option(name: .long, help: "Max fan speed decrease per second, fraction of max RPM (default 0.025)")
    var rampDown: Float = 0.025

    @Option(name: .long, help: "Seconds above the curve's start temp before fans engage (default 8)")
    var sustained: Float = 8

    func run() throws {
        let points = try parseCurvePoints(curve)
        let customCurve = try CustomCurve(points: points)
        let sensorConditions = try condition.map(parseCondition)
        let op = try parseConditionOperator(conditionOperator)

        let profile = try FanProfile.custom(
            id: id, name: name ?? id, customCurve: customCurve,
            sensorConditions: sensorConditions, conditionOperator: op,
            rampUpPerSec: rampUp, rampDownPerSec: rampDown,
            sustainedTriggerSec: sustained, maxRPMPercent: maxPercent
        )
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
