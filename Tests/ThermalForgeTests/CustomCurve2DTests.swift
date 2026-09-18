//
//  CustomCurve2DTests.swift
//  ThermalForge
//
//  Dual-sensor Custom Curve: each point is (CPU, GPU) → fan%, evaluated via
//  inverse-distance weighting (see CustomCurve2D's doc comment for why).
//

import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("CustomCurve2D")
struct CustomCurve2DTests {
    static let sample = try! CustomCurve2D(points: [
        FanCurvePoint2D(cpuTemp: 50, gpuTemp: 40, fanPercent: 0),
        FanCurvePoint2D(cpuTemp: 60, gpuTemp: 50, fanPercent: 30),
        FanCurvePoint2D(cpuTemp: 70, gpuTemp: 60, fanPercent: 60),
        FanCurvePoint2D(cpuTemp: 80, gpuTemp: 70, fanPercent: 100),
    ])

    @Test("an exact match to a point returns that point's percentage")
    func exactMatch() {
        #expect(Self.sample.evaluate(cpuTemp: 60, gpuTemp: 50) == 30)
        #expect(Self.sample.evaluate(cpuTemp: 80, gpuTemp: 70) == 100)
    }

    @Test("a single-point curve always returns that point's percentage")
    func singlePoint() throws {
        let curve = try CustomCurve2D(points: [FanCurvePoint2D(cpuTemp: 60, gpuTemp: 55, fanPercent: 42)])
        #expect(curve.evaluate(cpuTemp: 0, gpuTemp: 0) == 42)
        #expect(curve.evaluate(cpuTemp: 60, gpuTemp: 55) == 42)
        #expect(curve.evaluate(cpuTemp: 200, gpuTemp: 200) == 42)
    }

    @Test("a reading exactly between two equally-weighted points averages them")
    func symmetricMidpoint() throws {
        let curve = try CustomCurve2D(points: [
            FanCurvePoint2D(cpuTemp: 0, gpuTemp: 0, fanPercent: 0),
            FanCurvePoint2D(cpuTemp: 100, gpuTemp: 0, fanPercent: 100),
        ])
        // Equidistant from both points along the CPU axis.
        let mid = curve.evaluate(cpuTemp: 50, gpuTemp: 0)
        #expect(abs(mid - 50) < 0.01)
    }

    @Test("is always bounded within the defined fan percentages, however far outside the curve")
    func boundedEverywhere() {
        let readings: [(Float, Float)] = [(-1000, -1000), (0, 0), (55, 45), (1000, 1000), (80, 40), (50, 70)]
        for (cpu, gpu) in readings {
            let value = Self.sample.evaluate(cpuTemp: cpu, gpuTemp: gpu)
            #expect(value >= 0 && value <= 100, "evaluate(\(cpu), \(gpu)) = \(value) escaped [0, 100]")
        }
    }

    @Test("a point much closer than the others dominates the result")
    func closerPointDominates() {
        // (70, 60) is far closer to (71, 61) than any other sample point.
        let value = Self.sample.evaluate(cpuTemp: 71, gpuTemp: 61)
        #expect(abs(value - 60) < 5)
    }

    @Test("rejects an empty curve")
    func invalidEmpty() {
        #expect(throws: CustomCurve2D.ValidationError.empty) {
            try CustomCurve2D(points: [])
        }
    }

    @Test("rejects duplicate (CPU, GPU) points")
    func duplicatePoint() {
        #expect(throws: CustomCurve2D.ValidationError.duplicatePoint(cpuTemp: 60, gpuTemp: 50)) {
            try CustomCurve2D(points: [
                FanCurvePoint2D(cpuTemp: 60, gpuTemp: 50, fanPercent: 10),
                FanCurvePoint2D(cpuTemp: 60, gpuTemp: 50, fanPercent: 20),
            ])
        }
    }

    @Test("distinct CPU/GPU pairs sharing one axis value are not duplicates")
    func sameSingleAxisIsNotDuplicate() throws {
        // Same CPU, different GPU — a real, valid pair of points.
        let curve = try CustomCurve2D(points: [
            FanCurvePoint2D(cpuTemp: 60, gpuTemp: 40, fanPercent: 10),
            FanCurvePoint2D(cpuTemp: 60, gpuTemp: 50, fanPercent: 20),
        ])
        #expect(curve.points.count == 2)
    }

    @Test("rejects fan percentage below 0")
    func fanPercentBelowZero() {
        #expect(throws: CustomCurve2D.ValidationError.invalidFanPercent(-1)) {
            try CustomCurve2D(points: [FanCurvePoint2D(cpuTemp: 50, gpuTemp: 40, fanPercent: -1)])
        }
    }

    @Test("rejects fan percentage above 100")
    func fanPercentAboveHundred() {
        #expect(throws: CustomCurve2D.ValidationError.invalidFanPercent(101)) {
            try CustomCurve2D(points: [FanCurvePoint2D(cpuTemp: 50, gpuTemp: 40, fanPercent: 101)])
        }
    }

    @Test("rejects NaN or infinite temperatures")
    func invalidTemperatures() {
        #expect(throws: CustomCurve2D.ValidationError.self) {
            try CustomCurve2D(points: [FanCurvePoint2D(cpuTemp: .nan, gpuTemp: 40, fanPercent: 10)])
        }
        #expect(throws: CustomCurve2D.ValidationError.self) {
            try CustomCurve2D(points: [FanCurvePoint2D(cpuTemp: 50, gpuTemp: .infinity, fanPercent: 10)])
        }
    }

    @Test("rejects NaN or infinite fan percentage")
    func invalidFanPercentValues() {
        #expect(throws: CustomCurve2D.ValidationError.self) {
            try CustomCurve2D(points: [FanCurvePoint2D(cpuTemp: 50, gpuTemp: 40, fanPercent: .nan)])
        }
        #expect(throws: CustomCurve2D.ValidationError.self) {
            try CustomCurve2D(points: [FanCurvePoint2D(cpuTemp: 50, gpuTemp: 40, fanPercent: .infinity)])
        }
    }

    @Test("round-trips through JSON")
    func jsonRoundTrip() throws {
        let data = try JSONEncoder().encode(Self.sample)
        let decoded = try JSONDecoder().decode(CustomCurve2D.self, from: data)
        #expect(decoded == Self.sample)
    }
}
