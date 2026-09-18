//
//  CustomProfileTests.swift
//  ThermalForge
//
//  rq.md §13/§19/§24 — Custom Profile construction/validation, Custom Curve + Governor
//  composition (ramp/hysteresis/safety-ceiling still apply), and a regression guard
//  that built-in profiles are byte-for-byte unaffected by the new optional fields.
//

import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Custom Profile")
struct CustomProfileTests {
    static func sampleCurve() throws -> CustomCurve {
        try CustomCurve(points: [
            FanCurvePoint(temperature: 50, fanPercent: 0),
            FanCurvePoint(temperature: 55, fanPercent: 20),
            FanCurvePoint(temperature: 60, fanPercent: 35),
            FanCurvePoint(temperature: 65, fanPercent: 55),
            FanCurvePoint(temperature: 70, fanPercent: 75),
            FanCurvePoint(temperature: 75, fanPercent: 100),
        ])
    }

    @Test("rejects more than 2 sensor conditions")
    func tooManyConditions() throws {
        let curve = try Self.sampleCurve()
        let conditions = [
            SensorCondition(sensor: .cpu, comparison: .greaterThanOrEqual, threshold: 65),
            SensorCondition(sensor: .gpu, comparison: .greaterThanOrEqual, threshold: 60),
            SensorCondition(sensor: .cpu, comparison: .greaterThan, threshold: 80),
        ]
        #expect(throws: FanProfile.CustomProfileError.tooManyConditions(3)) {
            try FanProfile.custom(id: "dev", name: "Development", customCurve: curve, sensorConditions: conditions)
        }
    }

    @Test("2 conditions require an operator")
    func requiresOperator() throws {
        let curve = try Self.sampleCurve()
        let conditions = [
            SensorCondition(sensor: .cpu, comparison: .greaterThanOrEqual, threshold: 65),
            SensorCondition(sensor: .gpu, comparison: .greaterThanOrEqual, threshold: 60),
        ]
        #expect(throws: FanProfile.CustomProfileError.missingConditionOperator) {
            try FanProfile.custom(id: "dev", name: "Development", customCurve: curve, sensorConditions: conditions)
        }
    }

    @Test("the rq.md §13 'Development' example builds and evaluates")
    func developmentExample() throws {
        let curve = try Self.sampleCurve()
        let profile = try FanProfile.custom(
            id: "dev", name: "Development", customCurve: curve,
            sensorConditions: [
                SensorCondition(sensor: .cpu, comparison: .greaterThanOrEqual, threshold: 65),
                SensorCondition(sensor: .gpu, comparison: .greaterThanOrEqual, threshold: 60),
            ],
            conditionOperator: .or
        )
        #expect(profile.customCurve == curve)
        #expect(profile.sensorConditions.count == 2)
        #expect(profile.conditionOperator == .or)
        // Governor knobs derived from the curve's own bounds.
        #expect(profile.curve.startTemp == 50)
        #expect(profile.curve.stopTemp == 45) // 5°C hysteresis, matching FanProfile.hysteresisDegrees
    }

    @Test("Codable round-trips a Custom Profile, and decodes a pre-feature profile JSON")
    func codableRoundTrip() throws {
        let curve = try Self.sampleCurve()
        let profile = try FanProfile.custom(
            id: "dev", name: "Development", customCurve: curve,
            sensorConditions: [SensorCondition(sensor: .cpu, comparison: .greaterThanOrEqual, threshold: 65)]
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(FanProfile.self, from: data)
        #expect(decoded == profile)

        // Simulate a profile JSON saved before this feature existed (no customCurve/
        // sensorConditions/conditionOperator keys) — must still decode, not fail.
        let legacyJSON = """
            {"id":"legacy","name":"Legacy","curve":{"stopTemp":45,"startTemp":55,"ceilingTemp":65,\
            "maxRPMPercent":0.5,"handsOff":false,"alwaysOn":false,"curveShape":"linear",\
            "rampUpPerSec":0.05,"rampDownPerSec":0.025,"sustainedTriggerSec":3,"instantEngage":false}}
            """.data(using: .utf8)!
        let legacy = try JSONDecoder().decode(FanProfile.self, from: legacyJSON)
        #expect(legacy.customCurve == nil)
        #expect(legacy.sensorConditions == [])
        #expect(legacy.conditionOperator == nil)
    }

    @Test("Custom profiles save and load through the existing profile persistence")
    func saveLoad() throws {
        let curve = try Self.sampleCurve()
        let custom = try FanProfile.custom(id: "test_custom_curve", name: "Test Custom Curve", customCurve: curve)
        try custom.save()

        let loaded = FanProfile.loadAll()
        let found = loaded.first { $0.id == "test_custom_curve" }
        #expect(found?.customCurve == curve)

        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ThermalForge/profiles/test_custom_curve.json")
        try? FileManager.default.removeItem(at: path)
    }

    @Test("delete removes a saved Custom Profile")
    func delete() throws {
        let curve = try Self.sampleCurve()
        let custom = try FanProfile.custom(id: "test_delete_me", name: "Delete Me", customCurve: curve)
        try custom.save()
        #expect(FanProfile.loadAll().contains { $0.id == "test_delete_me" })

        try FanProfile.delete(id: "test_delete_me")
        #expect(!FanProfile.loadAll().contains { $0.id == "test_delete_me" })
    }

    @Test("delete throws for an id that was never saved")
    func deleteMissing() {
        #expect(throws: (any Error).self) {
            try FanProfile.delete(id: "does-not-exist-\(UUID().uuidString)")
        }
    }

    // MARK: - Curve + Governor composition (rq.md §19 spirit). ThermalMonitor itself
    // needs real SMC hardware to instantiate, so — like the rest of this suite —
    // the governor math is exercised directly at the same entry point
    // ThermalMonitor.tickCurve() calls: `Curve.targetPercent(customCurve:)`.

    @Test("a Custom Curve's target is capped by maxRPMPercent — the profile's safety ceiling")
    func maxRPMPercentCapsCustomCurve() throws {
        let curve = try CustomCurve(points: [
            FanCurvePoint(temperature: 50, fanPercent: 0),
            FanCurvePoint(temperature: 75, fanPercent: 100),
        ])
        let profile = try FanProfile.custom(id: "capped", name: "Capped", customCurve: curve, maxRPMPercent: 0.5)
        // At 75°C the curve wants 100%, but the profile's ceiling is 50% — the same
        // clamp every built-in profile's curve shape goes through.
        let target = profile.curve.targetPercent(at: 75, fansCurrentlyRunning: true, customCurve: profile.customCurve)
        #expect(target == 0.5)
    }

    @Test("hysteresis still governs a Custom Curve's on/off transitions")
    func hysteresisAppliesToCustomCurve() throws {
        let curve = try Self.sampleCurve()
        let profile = try FanProfile.custom(id: "dev", name: "Development", customCurve: curve)
        // Below stopTemp (45), fans not running: stay off.
        #expect(profile.curve.targetPercent(at: 44, fansCurrentlyRunning: false, customCurve: curve) == nil)
        // Between stop (45) and start (50), fans already running: hold at minimum.
        #expect(profile.curve.targetPercent(at: 47, fansCurrentlyRunning: true, customCurve: curve) == 0.001)
        // At start (50), the curve's own first point (0%) takes over.
        #expect(profile.curve.targetPercent(at: 50, fansCurrentlyRunning: false, customCurve: curve) == 0)
    }

    @Test("a not-satisfied sensor condition gate reports no target, same as the curve saying off")
    func conditionGateActsLikeCurveOff() throws {
        let curve = try Self.sampleCurve()
        let profile = try FanProfile.custom(
            id: "gated", name: "Gated", customCurve: curve,
            sensorConditions: [SensorCondition(sensor: .gpu, comparison: .greaterThanOrEqual, threshold: 60)]
        )
        var temps: [String: Float] = ["TC0P": 90] // CPU hot, but the only condition watches GPU
        let notHot = ThermalStatus(fans: [], temperatures: temps)
        #expect(SensorConditionEvaluator.isSatisfied(profile.sensorConditions, operator: profile.conditionOperator, in: notHot) == false)

        temps["TG0P"] = 65 // now GPU clears its threshold too
        let hot = ThermalStatus(fans: [], temperatures: temps)
        #expect(SensorConditionEvaluator.isSatisfied(profile.sensorConditions, operator: profile.conditionOperator, in: hot) == true)
    }

    // MARK: - Built-in profiles unaffected (rq.md §12 regression guard)

    @Test("a built-in profile's targetPercent is unchanged with the new optional param defaulted")
    func builtInProfilesUnaffected() {
        let curve = FanProfile.balanced.curve
        let withoutCustom = curve.targetPercent(at: 62.5, fansCurrentlyRunning: true)
        let explicitNil = curve.targetPercent(at: 62.5, fansCurrentlyRunning: true, customCurve: nil)
        #expect(withoutCustom == explicitNil)
        #expect(abs(withoutCustom! - 0.15) < 0.001) // easeIn midpoint, same as ProfileTests.balancedEaseIn
    }

    @Test("no built-in profile has sensor conditions or a custom curve")
    func builtInsHaveNoConditionsOrCustomCurve() {
        for profile in FanProfile.builtIn + [FanProfile.smart] {
            #expect(profile.customCurve == nil)
            #expect(profile.sensorConditions.isEmpty)
            #expect(profile.conditionOperator == nil)
        }
    }
}
