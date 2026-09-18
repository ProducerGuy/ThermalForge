//
//  CustomCurve2DTests.swift
//  ThermalForge
//
//  Dual-sensor Custom Curve: each point is (sensorA, sensorB) → fan%, evaluated via
//  inverse-distance weighting (see CustomCurve2D's doc comment for why). Sensors are
//  freely chosen from `Sensor`'s cases, not fixed to CPU/GPU.
//

import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("CustomCurve2D")
struct CustomCurve2DTests {
    static let sample = try! CustomCurve2D(sensorA: .cpu, sensorB: .gpu, points: [
        FanCurvePoint2D(sensorAValue: 50, sensorBValue: 40, fanPercent: 0),
        FanCurvePoint2D(sensorAValue: 60, sensorBValue: 50, fanPercent: 30),
        FanCurvePoint2D(sensorAValue: 70, sensorBValue: 60, fanPercent: 60),
        FanCurvePoint2D(sensorAValue: 80, sensorBValue: 70, fanPercent: 100),
    ])

    @Test("an exact match to a point returns that point's percentage")
    func exactMatch() {
        #expect(Self.sample.evaluate(sensorAValue: 60, sensorBValue: 50) == 30)
        #expect(Self.sample.evaluate(sensorAValue: 80, sensorBValue: 70) == 100)
    }

    @Test("a single-point curve always returns that point's percentage")
    func singlePoint() throws {
        let curve = try CustomCurve2D(sensorA: .cpu, sensorB: .gpu, points: [
            FanCurvePoint2D(sensorAValue: 60, sensorBValue: 55, fanPercent: 42),
        ])
        #expect(curve.evaluate(sensorAValue: 0, sensorBValue: 0) == 42)
        #expect(curve.evaluate(sensorAValue: 60, sensorBValue: 55) == 42)
        #expect(curve.evaluate(sensorAValue: 200, sensorBValue: 200) == 42)
    }

    @Test("any two distinct sensors can be chosen, not just CPU/GPU")
    func arbitrarySensorPair() throws {
        let curve = try CustomCurve2D(sensorA: .ram, sensorB: .ambient, points: [
            FanCurvePoint2D(sensorAValue: 40, sensorBValue: 20, fanPercent: 10),
            FanCurvePoint2D(sensorAValue: 60, sensorBValue: 30, fanPercent: 80),
        ])
        #expect(curve.sensorA == .ram)
        #expect(curve.sensorB == .ambient)
        #expect(curve.evaluate(sensorAValue: 60, sensorBValue: 30) == 80)
    }

    @Test("a reading exactly between two equally-weighted points averages them")
    func symmetricMidpoint() throws {
        let curve = try CustomCurve2D(sensorA: .cpu, sensorB: .gpu, points: [
            FanCurvePoint2D(sensorAValue: 0, sensorBValue: 0, fanPercent: 0),
            FanCurvePoint2D(sensorAValue: 100, sensorBValue: 0, fanPercent: 100),
        ])
        // Equidistant from both points along the A axis.
        let mid = curve.evaluate(sensorAValue: 50, sensorBValue: 0)
        #expect(abs(mid - 50) < 0.01)
    }

    @Test("is always bounded within the defined fan percentages, however far outside the curve")
    func boundedEverywhere() {
        let readings: [(Float, Float)] = [(-1000, -1000), (0, 0), (55, 45), (1000, 1000), (80, 40), (50, 70)]
        for (a, b) in readings {
            let value = Self.sample.evaluate(sensorAValue: a, sensorBValue: b)
            #expect(value >= 0 && value <= 100, "evaluate(\(a), \(b)) = \(value) escaped [0, 100]")
        }
    }

    @Test("a point much closer than the others dominates the result")
    func closerPointDominates() {
        // (70, 60) is far closer to (71, 61) than any other sample point.
        let value = Self.sample.evaluate(sensorAValue: 71, sensorBValue: 61)
        #expect(abs(value - 60) < 5)
    }

    @Test("rejects sensorA and sensorB being the same sensor")
    func rejectsSameSensor() {
        #expect(throws: CustomCurve2D.ValidationError.sameSensor(.cpu)) {
            try CustomCurve2D(sensorA: .cpu, sensorB: .cpu, points: [
                FanCurvePoint2D(sensorAValue: 50, sensorBValue: 40, fanPercent: 0),
            ])
        }
    }

    @Test("rejects an empty curve")
    func invalidEmpty() {
        #expect(throws: CustomCurve2D.ValidationError.empty) {
            try CustomCurve2D(sensorA: .cpu, sensorB: .gpu, points: [])
        }
    }

    @Test("rejects duplicate (sensorA, sensorB) points")
    func duplicatePoint() {
        #expect(throws: CustomCurve2D.ValidationError.duplicatePoint(sensorAValue: 60, sensorBValue: 50)) {
            try CustomCurve2D(sensorA: .cpu, sensorB: .gpu, points: [
                FanCurvePoint2D(sensorAValue: 60, sensorBValue: 50, fanPercent: 10),
                FanCurvePoint2D(sensorAValue: 60, sensorBValue: 50, fanPercent: 20),
            ])
        }
    }

    @Test("distinct pairs sharing one axis value are not duplicates")
    func sameSingleAxisIsNotDuplicate() throws {
        // Same sensorA reading, different sensorB — a real, valid pair of points.
        let curve = try CustomCurve2D(sensorA: .cpu, sensorB: .gpu, points: [
            FanCurvePoint2D(sensorAValue: 60, sensorBValue: 40, fanPercent: 10),
            FanCurvePoint2D(sensorAValue: 60, sensorBValue: 50, fanPercent: 20),
        ])
        #expect(curve.points.count == 2)
    }

    @Test("rejects fan percentage below 0")
    func fanPercentBelowZero() {
        #expect(throws: CustomCurve2D.ValidationError.invalidFanPercent(-1)) {
            try CustomCurve2D(sensorA: .cpu, sensorB: .gpu, points: [
                FanCurvePoint2D(sensorAValue: 50, sensorBValue: 40, fanPercent: -1),
            ])
        }
    }

    @Test("rejects fan percentage above 100")
    func fanPercentAboveHundred() {
        #expect(throws: CustomCurve2D.ValidationError.invalidFanPercent(101)) {
            try CustomCurve2D(sensorA: .cpu, sensorB: .gpu, points: [
                FanCurvePoint2D(sensorAValue: 50, sensorBValue: 40, fanPercent: 101),
            ])
        }
    }

    @Test("rejects NaN or infinite readings")
    func invalidReadings() {
        #expect(throws: CustomCurve2D.ValidationError.self) {
            try CustomCurve2D(sensorA: .cpu, sensorB: .gpu, points: [
                FanCurvePoint2D(sensorAValue: .nan, sensorBValue: 40, fanPercent: 10),
            ])
        }
        #expect(throws: CustomCurve2D.ValidationError.self) {
            try CustomCurve2D(sensorA: .cpu, sensorB: .gpu, points: [
                FanCurvePoint2D(sensorAValue: 50, sensorBValue: .infinity, fanPercent: 10),
            ])
        }
    }

    @Test("rejects NaN or infinite fan percentage")
    func invalidFanPercentValues() {
        #expect(throws: CustomCurve2D.ValidationError.self) {
            try CustomCurve2D(sensorA: .cpu, sensorB: .gpu, points: [
                FanCurvePoint2D(sensorAValue: 50, sensorBValue: 40, fanPercent: .nan),
            ])
        }
        #expect(throws: CustomCurve2D.ValidationError.self) {
            try CustomCurve2D(sensorA: .cpu, sensorB: .gpu, points: [
                FanCurvePoint2D(sensorAValue: 50, sensorBValue: 40, fanPercent: .infinity),
            ])
        }
    }

    @Test("round-trips through JSON")
    func jsonRoundTrip() throws {
        let data = try JSONEncoder().encode(Self.sample)
        let decoded = try JSONDecoder().decode(CustomCurve2D.self, from: data)
        #expect(decoded == Self.sample)
    }
}
