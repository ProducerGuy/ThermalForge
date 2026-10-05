//
//  CustomCurve.swift
//  ThermalForge
//
//  User-defined temperature → fan speed curves for Custom Profiles. Complements
//  FanProfile.Curve's fixed shape functions (linear/easeIn/easeOut/sCurve) with an
//  arbitrary set of points, linearly interpolated. Built-in profiles are untouched —
//  this is only consulted when a profile opts in via `FanProfile.customCurve`.
//

import Foundation

// MARK: - Curve Point

/// One Temperature → Fan Speed point in a `CustomCurve`.
public struct FanCurvePoint: Codable, Equatable, ColorZonePoint {
    /// Degrees Celsius.
    public let temperature: Float
    /// Fan speed as a percentage, 0...100.
    public let fanPercent: Float
    /// Menu bar icon color once the fan's actual speed reaches `fanPercent` — see
    /// `FanProfile.color(forActualFanPercent:)`. nil (the default) sets no color.
    public let color: PointColor?

    public init(temperature: Float, fanPercent: Float, color: PointColor? = nil) {
        self.temperature = temperature
        self.fanPercent = fanPercent
        self.color = color
    }
}

// MARK: - Custom Curve

/// A user-defined temperature → fan speed curve, linearly interpolated between
/// points. Validated at construction so an invalid curve can never reach the
/// governor — see `ValidationError` for the specific rules enforced.
public struct CustomCurve: Codable, Equatable {
    public let points: [FanCurvePoint]

    public enum ValidationError: Error, CustomStringConvertible, Equatable {
        case empty
        case invalidTemperature(Float)
        case invalidFanPercent(Float)
        case duplicateTemperature(Float)
        case unsorted

        public var description: String {
            switch self {
            case .empty:
                return "Custom curve needs at least one point"
            case .invalidTemperature(let t):
                return "Temperature \(t) is invalid (NaN/Infinity are not allowed)"
            case .invalidFanPercent(let p):
                return "Fan percent \(p) is out of range (0...100, and NaN/Infinity are not allowed)"
            case .duplicateTemperature(let t):
                return "Duplicate temperature \(t)°C — each point needs a distinct temperature"
            case .unsorted:
                return "Points must be sorted by ascending temperature"
            }
        }
    }

    /// Validates and constructs a curve. Points must be sorted strictly ascending by
    /// temperature (no duplicates), every temperature finite, and every fan percent a
    /// finite value in 0...100 — see rq.md §4 for the exact rules this enforces.
    public init(points: [FanCurvePoint]) throws {
        guard !points.isEmpty else { throw ValidationError.empty }

        for point in points {
            guard point.temperature.isFinite else {
                throw ValidationError.invalidTemperature(point.temperature)
            }
            guard point.fanPercent.isFinite, point.fanPercent >= 0, point.fanPercent <= 100 else {
                throw ValidationError.invalidFanPercent(point.fanPercent)
            }
        }

        for i in 1..<points.count {
            let prev = points[i - 1].temperature
            let curr = points[i].temperature
            guard curr != prev else { throw ValidationError.duplicateTemperature(curr) }
            guard curr > prev else { throw ValidationError.unsorted }
        }

        self.points = points
    }

    /// Linear interpolation between bracketing points. Below the first point's
    /// temperature, returns the first point's fan percentage; above the last point's,
    /// returns the last point's — see rq.md §3.3 for the exact boundary contract.
    public func evaluate(at temperature: Float) -> Float {
        let first = points[0]
        let last = points[points.count - 1]

        if temperature <= first.temperature { return first.fanPercent }
        if temperature >= last.temperature { return last.fanPercent }

        for i in 1..<points.count {
            let lower = points[i - 1]
            let upper = points[i]
            guard temperature <= upper.temperature else { continue }
            let span = upper.temperature - lower.temperature
            let position = (temperature - lower.temperature) / span
            return lower.fanPercent + position * (upper.fanPercent - lower.fanPercent)
        }

        return last.fanPercent
    }
}
