//
//  CustomProfileTests.swift
//  ThermalForge
//
//  rq.md §13/§19/§24 — Custom Profile construction, Custom Curve (1D and dual-sensor
//  2D) + Governor composition (ramp/hysteresis/safety-ceiling still apply), and a
//  regression guard that built-in profiles are byte-for-byte unaffected.
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

    static func sampleCurve2D() throws -> CustomCurve2D {
        try CustomCurve2D(sensorA: .cpu, sensorB: .gpu, points: [
            FanCurvePoint2D(sensorAValue: 50, sensorBValue: 40, fanPercent: 0),
            FanCurvePoint2D(sensorAValue: 65, sensorBValue: 55, fanPercent: 50),
            FanCurvePoint2D(sensorAValue: 80, sensorBValue: 70, fanPercent: 100),
        ])
    }

    // MARK: - Construction (1D)

    @Test("a single-axis Custom Profile builds and its governor knobs derive from the curve")
    func oneDimensionalExample() throws {
        let curve = try Self.sampleCurve()
        let profile = FanProfile.custom(id: "dev", name: "Development", customCurve: curve)
        #expect(profile.customCurve == curve)
        #expect(profile.customCurve2D == nil)
        #expect(profile.curve.startTemp == 50)
        #expect(profile.curve.stopTemp == 45) // 5°C hysteresis, matching FanProfile.hysteresisDegrees
    }

    // MARK: - Construction (2D)

    @Test("a dual-sensor Custom Profile builds and its governor knobs derive from the curve")
    func twoDimensionalExample() throws {
        let curve = try Self.sampleCurve2D()
        let profile = FanProfile.custom(id: "dual", name: "Dual", customCurve2D: curve)
        #expect(profile.customCurve2D == curve)
        #expect(profile.customCurve == nil)
        // startTemp = min over points of max(sensorAValue, sensorBValue): 50, 65, 80 → 50.
        #expect(profile.curve.startTemp == 50)
        #expect(profile.curve.stopTemp == 45)
    }

    @Test("a dual-sensor Custom Profile can be built from any pair, not just CPU/GPU")
    func arbitrarySensorPairProfile() throws {
        let curve = try CustomCurve2D(sensorA: .ram, sensorB: .ssd, points: [
            FanCurvePoint2D(sensorAValue: 40, sensorBValue: 35, fanPercent: 0),
            FanCurvePoint2D(sensorAValue: 60, sensorBValue: 55, fanPercent: 100),
        ])
        let profile = FanProfile.custom(id: "ramssd", name: "RAM+SSD", customCurve2D: curve)
        #expect(profile.customCurve2D?.sensorA == .ram)
        #expect(profile.customCurve2D?.sensorB == .ssd)
    }

    // MARK: - Codable / persistence

    @Test("Codable round-trips a single-axis Custom Profile, and decodes a pre-feature profile JSON")
    func codableRoundTripOneDimensional() throws {
        let curve = try Self.sampleCurve()
        let profile = FanProfile.custom(id: "dev", name: "Development", customCurve: curve)
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(FanProfile.self, from: data)
        #expect(decoded == profile)

        // Simulate a profile JSON saved before this feature existed (no customCurve/
        // customCurve2D keys) — must still decode, not fail.
        let legacyJSON = """
            {"id":"legacy","name":"Legacy","curve":{"stopTemp":45,"startTemp":55,"ceilingTemp":65,\
            "maxRPMPercent":0.5,"handsOff":false,"alwaysOn":false,"curveShape":"linear",\
            "rampUpPerSec":0.05,"rampDownPerSec":0.025,"sustainedTriggerSec":3,"instantEngage":false}}
            """.data(using: .utf8)!
        let legacy = try JSONDecoder().decode(FanProfile.self, from: legacyJSON)
        #expect(legacy.customCurve == nil)
        #expect(legacy.customCurve2D == nil)
    }

    @Test("Codable round-trips a dual-sensor Custom Profile, and ignores a pre-2D profile's leftover sensorConditions keys")
    func codableRoundTripTwoDimensional() throws {
        let curve = try Self.sampleCurve2D()
        let profile = FanProfile.custom(id: "dual", name: "Dual", customCurve2D: curve)
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(FanProfile.self, from: data)
        #expect(decoded == profile)

        // Simulate a profile JSON saved by the earlier sensor-condition design (now
        // removed) — the unknown extra keys must be ignored, not fail decoding.
        let oldGateDesignJSON = """
            {"id":"old","name":"Old","curve":{"stopTemp":45,"startTemp":50,"ceilingTemp":75,\
            "maxRPMPercent":1,"handsOff":false,"alwaysOn":false,"curveShape":"linear",\
            "rampUpPerSec":0.05,"rampDownPerSec":0.025,"sustainedTriggerSec":8,"instantEngage":false},\
            "customCurve":{"points":[{"temperature":50,"fanPercent":0},{"temperature":75,"fanPercent":100}]},\
            "sensorConditions":[{"sensor":"gpu","comparison":">=","threshold":60}],"conditionOperator":"or"}
            """.data(using: .utf8)!
        let old = try JSONDecoder().decode(FanProfile.self, from: oldGateDesignJSON)
        #expect(old.customCurve?.points.count == 2)
    }

    @Test("Custom Profiles (1D and 2D) save and load through the existing profile persistence")
    func saveLoad() throws {
        let curve1D = try Self.sampleCurve()
        let custom1D = FanProfile.custom(id: "test_custom_curve", name: "Test Custom Curve", customCurve: curve1D)
        try custom1D.save()

        let curve2D = try Self.sampleCurve2D()
        let custom2D = FanProfile.custom(id: "test_custom_curve_2d", name: "Test Custom Curve 2D", customCurve2D: curve2D)
        try custom2D.save()

        let loaded = FanProfile.loadAll()
        #expect(loaded.first { $0.id == "test_custom_curve" }?.customCurve == curve1D)
        #expect(loaded.first { $0.id == "test_custom_curve_2d" }?.customCurve2D == curve2D)

        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ThermalForge/profiles")
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("test_custom_curve.json"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("test_custom_curve_2d.json"))
    }

    @Test("delete removes a saved Custom Profile")
    func delete() throws {
        let curve = try Self.sampleCurve()
        let custom = FanProfile.custom(id: "test_delete_me", name: "Delete Me", customCurve: curve)
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
    // needs real SMC hardware to instantiate, so — like the rest of this suite — the
    // governor math is exercised directly at the same entry point ThermalMonitor.
    // tickCurve() calls: `Curve.targetPercent(customCurve:customCurve2D:)`.

    @Test("a single-axis Custom Curve's target is capped by maxRPMPercent — the profile's safety ceiling")
    func maxRPMPercentCapsCustomCurve() throws {
        let curve = try CustomCurve(points: [
            FanCurvePoint(temperature: 50, fanPercent: 0),
            FanCurvePoint(temperature: 75, fanPercent: 100),
        ])
        let profile = FanProfile.custom(id: "capped", name: "Capped", customCurve: curve, maxRPMPercent: 0.5)
        // At 75°C the curve wants 100%, but the profile's ceiling is 50% — the same
        // clamp every built-in profile's curve shape goes through.
        let target = profile.curve.targetPercent(at: 75, fansCurrentlyRunning: true, customCurve: profile.customCurve)
        #expect(target == 0.5)
    }

    @Test("a dual-sensor Custom Curve's target is capped by maxRPMPercent too")
    func maxRPMPercentCapsCustomCurve2D() throws {
        let curve = try Self.sampleCurve2D()
        let profile = FanProfile.custom(id: "capped2d", name: "Capped 2D", customCurve2D: curve, maxRPMPercent: 0.5)
        // Exactly the hot point (80, 70) wants 100%, but the ceiling is 50%.
        let target = profile.curve.targetPercent(
            at: 80, fansCurrentlyRunning: true,
            customCurve2D: (curve: curve, sensorAValue: 80, sensorBValue: 70)
        )
        #expect(target == 0.5)
    }

    @Test("hysteresis still governs a single-axis Custom Curve's on/off transitions")
    func hysteresisAppliesToCustomCurve() throws {
        let curve = try Self.sampleCurve()
        let profile = FanProfile.custom(id: "dev", name: "Development", customCurve: curve)
        // Below stopTemp (45), fans not running: stay off.
        #expect(profile.curve.targetPercent(at: 44, fansCurrentlyRunning: false, customCurve: curve) == nil)
        // Between stop (45) and start (50), fans already running: hold at minimum.
        #expect(profile.curve.targetPercent(at: 47, fansCurrentlyRunning: true, customCurve: curve) == 0.001)
        // At start (50), the curve's own first point (0%) takes over.
        #expect(profile.curve.targetPercent(at: 50, fansCurrentlyRunning: false, customCurve: curve) == 0)
    }

    @Test("hysteresis still governs a dual-sensor Custom Curve's on/off transitions — keyed on the peak temp, not the curve")
    func hysteresisAppliesToCustomCurve2D() throws {
        let curve = try Self.sampleCurve2D()
        let profile = FanProfile.custom(id: "dual", name: "Dual", customCurve2D: curve)
        let arg = (curve: curve, sensorAValue: Float(65), sensorBValue: Float(55))
        // Below stopTemp (45): off, regardless of what the 2D curve would say at (65,55).
        #expect(profile.curve.targetPercent(at: 44, fansCurrentlyRunning: false, customCurve2D: arg) == nil)
        // Above start (50): the 2D curve evaluates normally.
        #expect(profile.curve.targetPercent(at: 65, fansCurrentlyRunning: true, customCurve2D: arg) == 0.5)
    }

    @Test("a dual-sensor Custom Curve is genuinely shaped by both readings, not a single aggregate")
    func dualSensorUsesBothReadings() throws {
        let curve = try CustomCurve2D(sensorA: .cpu, sensorB: .gpu, points: [
            FanCurvePoint2D(sensorAValue: 50, sensorBValue: 90, fanPercent: 10), // hot GPU, cool CPU
            FanCurvePoint2D(sensorAValue: 90, sensorBValue: 50, fanPercent: 90), // hot CPU, cool GPU
        ])
        let profile = FanProfile.custom(id: "dual2", name: "Dual2", customCurve2D: curve)
        // Same peak temp (90) either way, but the curve should favor whichever
        // defined point the actual (CPU, GPU) reading is closer to — a single
        // aggregated "peak" temperature could never tell these two cases apart.
        let hotCPU = profile.curve.targetPercent(
            at: 90, fansCurrentlyRunning: true,
            customCurve2D: (curve: curve, sensorAValue: 90, sensorBValue: 50)
        )
        let hotGPU = profile.curve.targetPercent(
            at: 90, fansCurrentlyRunning: true,
            customCurve2D: (curve: curve, sensorAValue: 50, sensorBValue: 90)
        )
        #expect(hotCPU == 0.9)
        #expect(hotGPU == 0.1)
    }

    // MARK: - Built-in profiles unaffected (rq.md §12 regression guard)

    @Test("a built-in profile's targetPercent is unchanged with the new optional params defaulted")
    func builtInProfilesUnaffected() {
        let curve = FanProfile.balanced.curve
        let withoutCustom = curve.targetPercent(at: 62.5, fansCurrentlyRunning: true)
        let explicitNil = curve.targetPercent(at: 62.5, fansCurrentlyRunning: true, customCurve: nil, customCurve2D: nil)
        #expect(withoutCustom == explicitNil)
        #expect(abs(withoutCustom! - 0.15) < 0.001) // easeIn midpoint, same as ProfileTests.balancedEaseIn
    }

    @Test("no built-in profile has a custom curve of either kind")
    func builtInsHaveNoCustomCurve() {
        for profile in FanProfile.builtIn + [FanProfile.smart] {
            #expect(profile.customCurve == nil)
            #expect(profile.customCurve2D == nil)
        }
    }
}
