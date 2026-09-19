//
//  PointColorTests.swift
//  ThermalForge
//
//  A curve point's optional color drives the menu bar icon once the fan's ACTUAL
//  speed reaches it — see FanProfile.color(forActualFanPercent:).
//

import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("PointColor")
struct PointColorTests {
    static let red = PointColor(red: 1, green: 0, blue: 0)
    static let blue = PointColor(red: 0, green: 0, blue: 1)

    @Test("a profile with no custom curve never has a color")
    func builtInHasNoColor() {
        #expect(FanProfile.balanced.color(forActualFanPercent: 100) == nil)
    }

    @Test("no point colored — never a color, regardless of fan speed")
    func noColoredPoints() throws {
        let curve = try CustomCurve(points: [
            FanCurvePoint(temperature: 50, fanPercent: 0),
            FanCurvePoint(temperature: 75, fanPercent: 100),
        ])
        let profile = FanProfile.custom(id: "p", name: "P", customCurve: curve)
        #expect(profile.color(forActualFanPercent: 0) == nil)
        #expect(profile.color(forActualFanPercent: 100) == nil)
    }

    @Test("a colored point's color applies once the actual fan speed reaches it, not before")
    func singleColoredPointOneDimensional() throws {
        let curve = try CustomCurve(points: [
            FanCurvePoint(temperature: 50, fanPercent: 0),
            FanCurvePoint(temperature: 75, fanPercent: 100, color: Self.red),
        ])
        let profile = FanProfile.custom(id: "p", name: "P", customCurve: curve)
        #expect(profile.color(forActualFanPercent: 99) == nil)
        #expect(profile.color(forActualFanPercent: 100) == Self.red) // inclusive threshold
    }

    @Test("higher-threshold colored point wins once the fan has passed it, in a 1D curve")
    func twoColoredPointsOneDimensional() throws {
        let curve = try CustomCurve(points: [
            FanCurvePoint(temperature: 50, fanPercent: 30, color: Self.red),
            FanCurvePoint(temperature: 75, fanPercent: 70, color: Self.blue),
        ])
        let profile = FanProfile.custom(id: "p", name: "P", customCurve: curve)
        #expect(profile.color(forActualFanPercent: 10) == nil)
        #expect(profile.color(forActualFanPercent: 30) == Self.red)
        #expect(profile.color(forActualFanPercent: 50) == Self.red)
        #expect(profile.color(forActualFanPercent: 70) == Self.blue)
        #expect(profile.color(forActualFanPercent: 100) == Self.blue)
    }

    @Test("an uncolored point never wins even if its threshold is the highest reached")
    func uncoloredPointIgnored() throws {
        let curve = try CustomCurve(points: [
            FanCurvePoint(temperature: 50, fanPercent: 30, color: Self.red),
            FanCurvePoint(temperature: 75, fanPercent: 90), // no color
        ])
        let profile = FanProfile.custom(id: "p", name: "P", customCurve: curve)
        #expect(profile.color(forActualFanPercent: 95) == Self.red)
    }

    @Test("works the same way for a dual-sensor (2D) curve")
    func twoDimensional() throws {
        let curve = try CustomCurve2D(sensorA: .cpu, sensorB: .gpu, points: [
            FanCurvePoint2D(sensorAValue: 50, sensorBValue: 40, fanPercent: 30, color: Self.red),
            FanCurvePoint2D(sensorAValue: 80, sensorBValue: 70, fanPercent: 70, color: Self.blue),
        ])
        let profile = FanProfile.custom(id: "p2d", name: "P2D", customCurve2D: curve)
        #expect(profile.color(forActualFanPercent: 10) == nil)
        #expect(profile.color(forActualFanPercent: 40) == Self.red)
        #expect(profile.color(forActualFanPercent: 80) == Self.blue)
    }

    @Test("round-trips through JSON, and a profile saved before this field existed still decodes")
    func codableRoundTripAndBackCompat() throws {
        let point = FanCurvePoint(temperature: 60, fanPercent: 50, color: Self.red)
        let data = try JSONEncoder().encode(point)
        let decoded = try JSONDecoder().decode(FanCurvePoint.self, from: data)
        #expect(decoded == point)

        let legacyJSON = "{\"temperature\":60,\"fanPercent\":50}".data(using: .utf8)!
        let legacy = try JSONDecoder().decode(FanCurvePoint.self, from: legacyJSON)
        #expect(legacy.color == nil)
    }
}
