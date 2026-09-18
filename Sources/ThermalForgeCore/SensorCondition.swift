//
//  SensorCondition.swift
//  ThermalForge
//
//  Dual sensor conditions for Custom Profiles: 0-2 threshold checks against the CPU
//  or GPU peak temperature, combined with AND/OR. Reuses the same CPU/GPU prefix
//  grouping `ThermalStatus.safetyPeakTemp` and the menu bar already use, rather than
//  inventing a second sensor abstraction.
//

import Foundation

// MARK: - Sensor

/// Which peak temperature a `SensorCondition` reads. Mirrors the CPU (`TC`/`Tp`) and
/// GPU (`TG`/`Tg`) key-prefix grouping already used by `ThermalStatus.safetyPeakTemp`
/// and the menu bar's temperature rows.
public enum Sensor: String, Codable, Equatable, CaseIterable {
    case cpu
    case gpu

    var prefixes: [String] {
        switch self {
        case .cpu: return ["TC", "Tp"]
        case .gpu: return ["TG", "Tg"]
        }
    }

    /// This sensor's peak reading in a status snapshot, or nil if none of its keys
    /// are present — e.g. a GPU-less Mac, or a transient read failure.
    public func temperature(in status: ThermalStatus) -> Float? {
        let values = status.temperatures.filter { key, _ in prefixes.contains { key.hasPrefix($0) } }.values
        return values.isEmpty ? nil : values.max()
    }
}

// MARK: - Comparison

public enum ComparisonOperator: String, Codable, Equatable {
    case greaterThan = ">"
    case greaterThanOrEqual = ">="
    case lessThan = "<"
    case lessThanOrEqual = "<="

    public func evaluate(_ lhs: Float, _ rhs: Float) -> Bool {
        switch self {
        case .greaterThan: return lhs > rhs
        case .greaterThanOrEqual: return lhs >= rhs
        case .lessThan: return lhs < rhs
        case .lessThanOrEqual: return lhs <= rhs
        }
    }
}

// MARK: - Sensor Condition

public struct SensorCondition: Codable, Equatable {
    public let sensor: Sensor
    public let comparison: ComparisonOperator
    public let threshold: Float

    public init(sensor: Sensor, comparison: ComparisonOperator, threshold: Float) {
        self.sensor = sensor
        self.comparison = comparison
        self.threshold = threshold
    }

    /// Evaluates against a status snapshot. Returns nil — never false — when the
    /// sensor is unavailable, so a missing reading is never silently read as 0°C
    /// (rq.md §10). Callers decide how an unknown result folds into AND/OR.
    public func isSatisfied(in status: ThermalStatus) -> Bool? {
        guard let temp = sensor.temperature(in: status) else { return nil }
        return comparison.evaluate(temp, threshold)
    }
}

// MARK: - Condition Operator

public enum ConditionOperator: String, Codable, Equatable {
    case and
    case or
}

// MARK: - Evaluator

/// Combines a Custom Profile's 0-2 sensor conditions into a single active/inactive
/// decision — the "Condition evaluation" stage in rq.md §22's architecture diagram,
/// kept separate from curve evaluation so it stays independently testable.
public enum SensorConditionEvaluator {
    /// - 0 conditions: always satisfied — the profile has no extra gate, matching
    ///   every built-in profile's behavior today.
    /// - 1 condition: that condition's result; an unavailable sensor is treated as
    ///   not satisfied (nothing to prove the condition true).
    /// - 2 conditions: combined per `op`. AND treats an unavailable leg as not
    ///   satisfied (AND can't be proven true from a missing reading). OR treats an
    ///   unavailable leg as not satisfied for THAT leg but still lets the other leg
    ///   decide — so a single dead sensor can't silently disable an OR gate that the
    ///   other sensor alone would have satisfied.
    public static func isSatisfied(
        _ conditions: [SensorCondition], operator op: ConditionOperator?, in status: ThermalStatus
    ) -> Bool {
        switch conditions.count {
        case 0:
            return true
        case 1:
            return conditions[0].isSatisfied(in: status) ?? false
        default:
            let a = conditions[0].isSatisfied(in: status) ?? false
            let b = conditions[1].isSatisfied(in: status) ?? false
            switch op {
            case .and: return a && b
            case .or: return a || b
            case nil: return false
            }
        }
    }
}
