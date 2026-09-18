//
//  CustomCurve2D.swift
//  ThermalForge
//
//  A genuinely dual-sensor Custom Curve: each point is (sensorA reading, sensorB
//  reading) → fan%, not a single temperature axis gated by a separate condition.
//  Which two sensors (any of `Sensor`'s cases — CPU/GPU/RAM/SSD/Ambient, not just
//  CPU/GPU) is chosen ONCE for the whole curve, not per point.
//

import Foundation

// MARK: - Curve Point

/// One (sensorA reading, sensorB reading) → Fan % point in a `CustomCurve2D`. Which
/// physical sensors A and B are is the curve's own `sensorA`/`sensorB`, not stored
/// per point — every point in a curve shares the same pair.
public struct FanCurvePoint2D: Codable, Equatable {
    /// Degrees Celsius, read from the curve's `sensorA`.
    public let sensorAValue: Float
    /// Degrees Celsius, read from the curve's `sensorB`.
    public let sensorBValue: Float
    /// Fan speed as a percentage, 0...100.
    public let fanPercent: Float

    public init(sensorAValue: Float, sensorBValue: Float, fanPercent: Float) {
        self.sensorAValue = sensorAValue
        self.sensorBValue = sensorBValue
        self.fanPercent = fanPercent
    }
}

// MARK: - Custom Curve (2D)

/// A user-defined (sensorA, sensorB) → fan% curve. Unlike `CustomCurve`'s single
/// axis, points here aren't ordered along one line, so "linear interpolation between
/// neighbors" isn't well-defined without a triangulation of the point set. Instead,
/// `evaluate` uses inverse-distance weighting (Shepard's method): every point
/// contributes to the result, weighted by how close it is (in 2D reading-space) to
/// the current readings. That keeps evaluation well-defined for any set of scattered
/// points — add, edit, delete, and reorder all just work, with no grid or
/// triangulation to maintain — and the result is always a weighted blend of the
/// defined fan percentages, so it can never overshoot past the min/max the user
/// configured, however far the readings are from every point.
public struct CustomCurve2D: Codable, Equatable {
    /// Which two sensors this curve reads — chosen once for the whole curve, e.g. CPU
    /// + GPU, or CPU + Ambient. Must differ from each other.
    public let sensorA: Sensor
    public let sensorB: Sensor
    public let points: [FanCurvePoint2D]

    public enum ValidationError: Error, CustomStringConvertible, Equatable {
        case empty
        case sameSensor(Sensor)
        case invalidValue(Float)
        case invalidFanPercent(Float)
        case duplicatePoint(sensorAValue: Float, sensorBValue: Float)

        public var description: String {
            switch self {
            case .empty:
                return "Custom curve needs at least one point"
            case .sameSensor(let sensor):
                return "sensorA and sensorB must differ, both were \(sensor.displayName)"
            case .invalidValue(let t):
                return "Reading \(t) is invalid (NaN/Infinity are not allowed)"
            case .invalidFanPercent(let p):
                return "Fan percent \(p) is out of range (0...100, and NaN/Infinity are not allowed)"
            case .duplicatePoint(let a, let b):
                return "Duplicate point at \(a) / \(b) — each point needs a distinct (sensorA, sensorB) pair"
            }
        }
    }

    /// Validates and constructs a curve: `sensorA` and `sensorB` differ, every
    /// reading finite, every fan percent a finite value in 0...100, and no two points
    /// sharing the same (sensorA, sensorB) pair (that would make `evaluate` at
    /// exactly that point ambiguous).
    public init(sensorA: Sensor, sensorB: Sensor, points: [FanCurvePoint2D]) throws {
        guard sensorA != sensorB else { throw ValidationError.sameSensor(sensorA) }
        guard !points.isEmpty else { throw ValidationError.empty }

        for point in points {
            guard point.sensorAValue.isFinite else { throw ValidationError.invalidValue(point.sensorAValue) }
            guard point.sensorBValue.isFinite else { throw ValidationError.invalidValue(point.sensorBValue) }
            guard point.fanPercent.isFinite, point.fanPercent >= 0, point.fanPercent <= 100 else {
                throw ValidationError.invalidFanPercent(point.fanPercent)
            }
        }

        for i in 0..<points.count {
            for j in (i + 1)..<points.count where points[i].sensorAValue == points[j].sensorAValue
                && points[i].sensorBValue == points[j].sensorBValue {
                throw ValidationError.duplicatePoint(sensorAValue: points[i].sensorAValue, sensorBValue: points[i].sensorBValue)
            }
        }

        self.sensorA = sensorA
        self.sensorB = sensorB
        self.points = points
    }

    /// Fan % for given (sensorA, sensorB) readings — see the type doc for why this is
    /// inverse-distance weighting rather than the 1D curve's linear interpolation.
    public func evaluate(sensorAValue: Float, sensorBValue: Float) -> Float {
        // A reading that (effectively) coincides with a defined point returns it
        // directly — both because that's the obviously correct answer and to avoid
        // dividing by ~0 in the distance weights below.
        if let exact = points.first(where: {
            abs($0.sensorAValue - sensorAValue) < 0.01 && abs($0.sensorBValue - sensorBValue) < 0.01
        }) {
            return exact.fanPercent
        }

        // Double precision for the accumulation: distances can be small and points
        // many, and this runs every tick, so it's worth not losing precision to Float.
        var weightedSum = 0.0
        var weightTotal = 0.0
        for point in points {
            let dx = Double(point.sensorAValue - sensorAValue)
            let dy = Double(point.sensorBValue - sensorBValue)
            let weight = 1.0 / (dx * dx + dy * dy) // inverse-square distance
            weightedSum += weight * Double(point.fanPercent)
            weightTotal += weight
        }
        return Float(weightedSum / weightTotal)
    }
}
