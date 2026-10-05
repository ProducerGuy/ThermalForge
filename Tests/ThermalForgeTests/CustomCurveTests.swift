//
//  CustomCurveTests.swift
//  ThermalForge
//
//  rq.md §17 — Custom Fan Curve: linear interpolation, boundary behavior, validation.
//

import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("CustomCurve")
struct CustomCurveTests {
    static let sample = try! CustomCurve(points: [
        FanCurvePoint(temperature: 50, fanPercent: 0),
        FanCurvePoint(temperature: 55, fanPercent: 20),
        FanCurvePoint(temperature: 60, fanPercent: 35),
        FanCurvePoint(temperature: 65, fanPercent: 55),
        FanCurvePoint(temperature: 70, fanPercent: 75),
        FanCurvePoint(temperature: 75, fanPercent: 100),
    ])

    @Test("temperature below first point uses the first point's percentage")
    func belowFirst() {
        #expect(Self.sample.evaluate(at: 40) == 0)
    }

    @Test("temperature exactly at the first point")
    func exactlyFirst() {
        #expect(Self.sample.evaluate(at: 50) == 0)
    }

    @Test("temperature between points interpolates linearly")
    func between() {
        // 62.5 between 60→35% and 65→55%: 35 + 0.5*(55-35) = 45
        let v = Self.sample.evaluate(at: 62.5)
        #expect(abs(v - 45) < 0.001)
    }

    @Test("temperature exactly at a middle point")
    func exactlyMiddle() {
        #expect(Self.sample.evaluate(at: 60) == 35)
    }

    @Test("temperature exactly at the last point")
    func exactlyLast() {
        #expect(Self.sample.evaluate(at: 75) == 100)
    }

    @Test("temperature above the last point uses the last point's percentage")
    func aboveLast() {
        #expect(Self.sample.evaluate(at: 90) == 100)
    }

    @Test("a single-point curve always returns that point's percentage")
    func singlePoint() throws {
        let curve = try CustomCurve(points: [FanCurvePoint(temperature: 60, fanPercent: 42)])
        #expect(curve.evaluate(at: 10) == 42)
        #expect(curve.evaluate(at: 60) == 42)
        #expect(curve.evaluate(at: 200) == 42)
    }

    @Test("rejects an empty curve")
    func invalidEmpty() {
        #expect(throws: CustomCurve.ValidationError.empty) {
            try CustomCurve(points: [])
        }
    }

    @Test("rejects duplicate temperatures")
    func duplicateTemperature() {
        #expect(throws: CustomCurve.ValidationError.duplicateTemperature(60)) {
            try CustomCurve(points: [
                FanCurvePoint(temperature: 60, fanPercent: 10),
                FanCurvePoint(temperature: 60, fanPercent: 20),
            ])
        }
    }

    @Test("rejects unsorted points")
    func unsorted() {
        #expect(throws: CustomCurve.ValidationError.unsorted) {
            try CustomCurve(points: [
                FanCurvePoint(temperature: 60, fanPercent: 10),
                FanCurvePoint(temperature: 55, fanPercent: 5),
            ])
        }
    }

    @Test("rejects fan percentage below 0")
    func fanPercentBelowZero() {
        #expect(throws: CustomCurve.ValidationError.invalidFanPercent(-1)) {
            try CustomCurve(points: [FanCurvePoint(temperature: 50, fanPercent: -1)])
        }
    }

    @Test("rejects fan percentage above 100")
    func fanPercentAboveHundred() {
        #expect(throws: CustomCurve.ValidationError.invalidFanPercent(101)) {
            try CustomCurve(points: [FanCurvePoint(temperature: 50, fanPercent: 101)])
        }
    }

    @Test("rejects NaN temperature")
    func nanTemperature() {
        #expect(throws: CustomCurve.ValidationError.self) {
            try CustomCurve(points: [FanCurvePoint(temperature: .nan, fanPercent: 10)])
        }
    }

    @Test("rejects infinite temperature")
    func infiniteTemperature() {
        #expect(throws: CustomCurve.ValidationError.self) {
            try CustomCurve(points: [FanCurvePoint(temperature: .infinity, fanPercent: 10)])
        }
    }

    @Test("rejects NaN fan percentage")
    func nanFanPercent() {
        #expect(throws: CustomCurve.ValidationError.self) {
            try CustomCurve(points: [FanCurvePoint(temperature: 50, fanPercent: .nan)])
        }
    }

    @Test("rejects infinite fan percentage")
    func infiniteFanPercent() {
        #expect(throws: CustomCurve.ValidationError.self) {
            try CustomCurve(points: [FanCurvePoint(temperature: 50, fanPercent: .infinity)])
        }
    }

    @Test("round-trips through JSON")
    func jsonRoundTrip() throws {
        let data = try JSONEncoder().encode(Self.sample)
        let decoded = try JSONDecoder().decode(CustomCurve.self, from: data)
        #expect(decoded == Self.sample)
    }
}
