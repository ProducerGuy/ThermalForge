//
//  CustomCurve2D.swift
//  ThermalForge
//
//  A genuinely dual-sensor Custom Curve: each point is (CPU temp, GPU temp) → fan%,
//  not a single temperature axis gated by a separate condition. Complements
//  `CustomCurve` (single axis) for profiles where both sensors should jointly shape
//  the curve, per points defined directly in terms of both readings.
//

import Foundation

// MARK: - Curve Point

/// One (CPU temp, GPU temp) → Fan % point in a `CustomCurve2D`.
public struct FanCurvePoint2D: Codable, Equatable {
    /// Degrees Celsius.
    public let cpuTemp: Float
    /// Degrees Celsius.
    public let gpuTemp: Float
    /// Fan speed as a percentage, 0...100.
    public let fanPercent: Float

    public init(cpuTemp: Float, gpuTemp: Float, fanPercent: Float) {
        self.cpuTemp = cpuTemp
        self.gpuTemp = gpuTemp
        self.fanPercent = fanPercent
    }
}

// MARK: - Custom Curve (2D)

/// A user-defined (CPU, GPU) → fan% curve. Unlike `CustomCurve`'s single axis, points
/// here aren't ordered along one line, so "linear interpolation between neighbors"
/// isn't well-defined without a triangulation of the point set. Instead, `evaluate`
/// uses inverse-distance weighting (Shepard's method): every point contributes to the
/// result, weighted by how close it is (in 2D temperature space) to the current
/// reading. That keeps evaluation well-defined for any set of scattered points — add,
/// edit, delete, and reorder all just work, with no grid or triangulation to maintain —
/// and the result is always a weighted blend of the defined fan percentages, so it can
/// never overshoot past the min/max the user configured, however far the reading is
/// from every point.
public struct CustomCurve2D: Codable, Equatable {
    public let points: [FanCurvePoint2D]

    public enum ValidationError: Error, CustomStringConvertible, Equatable {
        case empty
        case invalidTemperature(Float)
        case invalidFanPercent(Float)
        case duplicatePoint(cpuTemp: Float, gpuTemp: Float)

        public var description: String {
            switch self {
            case .empty:
                return "Custom curve needs at least one point"
            case .invalidTemperature(let t):
                return "Temperature \(t) is invalid (NaN/Infinity are not allowed)"
            case .invalidFanPercent(let p):
                return "Fan percent \(p) is out of range (0...100, and NaN/Infinity are not allowed)"
            case .duplicatePoint(let cpu, let gpu):
                return "Duplicate point at CPU \(cpu)°C / GPU \(gpu)°C — each point needs a distinct (CPU, GPU) pair"
            }
        }
    }

    /// Validates and constructs a curve: every temperature finite, every fan percent a
    /// finite value in 0...100, and no two points sharing the same (CPU, GPU) pair
    /// (that would make `evaluate` at exactly that point ambiguous).
    public init(points: [FanCurvePoint2D]) throws {
        guard !points.isEmpty else { throw ValidationError.empty }

        for point in points {
            guard point.cpuTemp.isFinite else { throw ValidationError.invalidTemperature(point.cpuTemp) }
            guard point.gpuTemp.isFinite else { throw ValidationError.invalidTemperature(point.gpuTemp) }
            guard point.fanPercent.isFinite, point.fanPercent >= 0, point.fanPercent <= 100 else {
                throw ValidationError.invalidFanPercent(point.fanPercent)
            }
        }

        for i in 0..<points.count {
            for j in (i + 1)..<points.count where points[i].cpuTemp == points[j].cpuTemp
                && points[i].gpuTemp == points[j].gpuTemp {
                throw ValidationError.duplicatePoint(cpuTemp: points[i].cpuTemp, gpuTemp: points[i].gpuTemp)
            }
        }

        self.points = points
    }

    /// Fan % for a given (CPU, GPU) reading — see the type doc for why this is
    /// inverse-distance weighting rather than the 1D curve's linear interpolation.
    public func evaluate(cpuTemp: Float, gpuTemp: Float) -> Float {
        // A reading that (effectively) coincides with a defined point returns it
        // directly — both because that's the obviously correct answer and to avoid
        // dividing by ~0 in the distance weights below.
        if let exact = points.first(where: {
            abs($0.cpuTemp - cpuTemp) < 0.01 && abs($0.gpuTemp - gpuTemp) < 0.01
        }) {
            return exact.fanPercent
        }

        // Double precision for the accumulation: distances can be small and points
        // many, and this runs every tick, so it's worth not losing precision to Float.
        var weightedSum = 0.0
        var weightTotal = 0.0
        for point in points {
            let dx = Double(point.cpuTemp - cpuTemp)
            let dy = Double(point.gpuTemp - gpuTemp)
            let weight = 1.0 / (dx * dx + dy * dy) // inverse-square distance
            weightedSum += weight * Double(point.fanPercent)
            weightTotal += weight
        }
        return Float(weightedSum / weightTotal)
    }
}
