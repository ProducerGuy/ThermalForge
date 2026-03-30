//
//  ProfileTests.swift
//  ThermalForge
//

import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Profiles")
struct ProfileTests {

    @Test("Built-in profiles have correct curve parameters")
    func builtInCurves() {
        // Silent: hands-off, 73-78°C intervention
        #expect(FanProfile.silent.curve.handsOff == true)
        #expect(FanProfile.silent.curve.stopTemp == 73)
        #expect(FanProfile.silent.curve.startTemp == 78)

        // Balanced: 50-60-70°C, 60% max
        #expect(FanProfile.balanced.curve.stopTemp == 50)
        #expect(FanProfile.balanced.curve.startTemp == 60)
        #expect(FanProfile.balanced.curve.ceilingTemp == 70)
        #expect(FanProfile.balanced.curve.maxRPMPercent == 0.60)

        // Performance: 45-50-65°C, 85% max
        #expect(FanProfile.performance.curve.stopTemp == 45)
        #expect(FanProfile.performance.curve.startTemp == 50)
        #expect(FanProfile.performance.curve.ceilingTemp == 65)
        #expect(FanProfile.performance.curve.maxRPMPercent == 0.85)

        // Max: always on at 100%
        #expect(FanProfile.max.curve.alwaysOn == true)
        #expect(FanProfile.max.curve.maxRPMPercent == 1.0)
    }

    @Test("Four built-in profiles exist")
    func builtInCount() {
        #expect(FanProfile.builtIn.count == 4)
        let ids = FanProfile.builtIn.map(\.id)
        #expect(ids.contains("silent"))
        #expect(ids.contains("balanced"))
        #expect(ids.contains("performance"))
        #expect(ids.contains("max"))
    }

    @Test("Profile round-trips through JSON")
    func jsonRoundTrip() throws {
        for profile in FanProfile.builtIn {
            let data = try JSONEncoder().encode(profile)
            let decoded = try JSONDecoder().decode(FanProfile.self, from: data)
            #expect(decoded == profile, "Round-trip failed for \(profile.name)")
        }
    }

    @Test("Custom profile saves and loads")
    func saveLoad() throws {
        let custom = FanProfile(
            id: "test_custom",
            name: "Test Custom",
            curve: FanProfile.Curve(stopTemp: 45, startTemp: 55, ceilingTemp: 65, maxRPMPercent: 0.50)
        )

        try custom.save()

        let loaded = FanProfile.loadAll()
        let found = loaded.first { $0.id == "test_custom" }
        #expect(found != nil)
        #expect(found?.curve.startTemp == 55)
        #expect(found?.curve.maxRPMPercent == 0.50)

        // Clean up
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ThermalForge/profiles/test_custom.json")
        try? FileManager.default.removeItem(at: path)
    }

    @Test("Safety threshold is 95°C")
    func safetyThreshold() {
        #expect(FanProfile.safetyTempThreshold == 95.0)
    }

    @Test("Hysteresis deadband is 5°C")
    func hysteresis() {
        #expect(FanProfile.hysteresisDegrees == 5.0)
    }

    @Test("Balanced curve produces correct fan percentages")
    func balancedCurve() {
        let curve = FanProfile.balanced.curve

        // Below stop: fans off
        #expect(curve.targetPercent(at: 45, fansCurrentlyRunning: false) == nil)

        // At start: should return a value (fans start)
        let atStart = curve.targetPercent(at: 60, fansCurrentlyRunning: false)
        #expect(atStart != nil)
        #expect(atStart! >= 0)

        // At ceiling: should be at maxRPMPercent
        let atCeiling = curve.targetPercent(at: 70, fansCurrentlyRunning: true)
        #expect(atCeiling == 0.60)

        // Midpoint: should be proportional
        let atMid = curve.targetPercent(at: 65, fansCurrentlyRunning: true)
        #expect(atMid != nil)
        #expect(atMid! > 0)
        #expect(atMid! < 0.60)
    }

    @Test("Max profile is always on")
    func maxAlwaysOn() {
        let curve = FanProfile.max.curve
        #expect(curve.targetPercent(at: 30, fansCurrentlyRunning: false) == 1.0)
        #expect(curve.targetPercent(at: 90, fansCurrentlyRunning: true) == 1.0)
    }

    @Test("Silent profile is hands-off")
    func silentHandsOff() {
        let curve = FanProfile.silent.curve
        #expect(curve.targetPercent(at: 50, fansCurrentlyRunning: false) == nil)
        #expect(curve.targetPercent(at: 70, fansCurrentlyRunning: false) == nil)
    }
}
