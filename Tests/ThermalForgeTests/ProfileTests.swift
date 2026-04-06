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
        // Silent (Apple Default): hands-off
        #expect(FanProfile.silent.curve.handsOff == true)
        #expect(FanProfile.silent.name == "Silent (Apple Default)")

        // All active profiles share 50°C off threshold
        #expect(FanProfile.balanced.curve.stopTemp == 50)
        #expect(FanProfile.performance.curve.stopTemp == 50)
        #expect(FanProfile.max.curve.stopTemp == 50)
        #expect(FanProfile.smart.curve.stopTemp == 50)

        // Balanced: 50-55-70°C, 60% max
        #expect(FanProfile.balanced.curve.startTemp == 55)
        #expect(FanProfile.balanced.curve.ceilingTemp == 70)
        #expect(FanProfile.balanced.curve.maxRPMPercent == 0.60)

        // Performance: 50-55-65°C, 85% max
        #expect(FanProfile.performance.curve.startTemp == 55)
        #expect(FanProfile.performance.curve.ceilingTemp == 65)
        #expect(FanProfile.performance.curve.maxRPMPercent == 0.85)

        // Max: 50-55-65°C, 100% (with ramp, not always-on)
        #expect(FanProfile.max.curve.alwaysOn == false)
        #expect(FanProfile.max.curve.startTemp == 55)
        #expect(FanProfile.max.curve.maxRPMPercent == 1.0)

        // Smart: 50-53-85°C, 100%
        #expect(FanProfile.smart.curve.startTemp == 53)
        #expect(FanProfile.smart.curve.ceilingTemp == 85)
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

        // Below stop (50°C): fans off
        #expect(curve.targetPercent(at: 45, fansCurrentlyRunning: false) == nil)

        // At start (55°C): should return a value
        let atStart = curve.targetPercent(at: 55, fansCurrentlyRunning: false)
        #expect(atStart != nil)
        #expect(atStart! >= 0)

        // At ceiling (70°C): should be at maxRPMPercent
        let atCeiling = curve.targetPercent(at: 70, fansCurrentlyRunning: true)
        #expect(atCeiling == 0.60)

        // Midpoint (62.5°C): should be proportional
        let atMid = curve.targetPercent(at: 62.5, fansCurrentlyRunning: true)
        #expect(atMid != nil)
        #expect(atMid! > 0)
        #expect(atMid! < 0.60)
    }

    @Test("Max profile uses curve with 100% ceiling")
    func maxCurve() {
        let curve = FanProfile.max.curve
        // Below stop (50°C): fans off
        #expect(curve.targetPercent(at: 45, fansCurrentlyRunning: false) == nil)
        // At ceiling (65°C): 100%
        #expect(curve.targetPercent(at: 65, fansCurrentlyRunning: true) == 1.0)
        // Above ceiling: still 100%
        #expect(curve.targetPercent(at: 80, fansCurrentlyRunning: true) == 1.0)
    }

    @Test("Silent profile is hands-off")
    func silentHandsOff() {
        let curve = FanProfile.silent.curve
        #expect(curve.targetPercent(at: 50, fansCurrentlyRunning: false) == nil)
        #expect(curve.targetPercent(at: 70, fansCurrentlyRunning: false) == nil)
    }

    @Test("Smart profile has correct curve parameters")
    func smartCurve() {
        let smart = FanProfile.smart
        #expect(smart.curve.stopTemp == 50)
        #expect(smart.curve.startTemp == 53)
        #expect(smart.curve.ceilingTemp == 85)
        #expect(smart.curve.maxRPMPercent == 1.0)
        #expect(smart.curve.handsOff == false)
        #expect(smart.curve.alwaysOn == false)
    }

    @Test("Balanced hysteresis: fans stay on between stop and start temps")
    func balancedHysteresis() {
        let curve = FanProfile.balanced.curve

        // 52°C: above stop (50), below start (55), fans running → keep at minimum
        let keepOn = curve.targetPercent(at: 52, fansCurrentlyRunning: true)
        #expect(keepOn != nil) // should return 0.001 (minimum hold signal)

        // 52°C: above stop (50), below start (55), fans NOT running → stay off
        let stayOff = curve.targetPercent(at: 52, fansCurrentlyRunning: false)
        #expect(stayOff == nil)

        // 48°C: below stop (50), fans running → turn off
        let turnOff = curve.targetPercent(at: 48, fansCurrentlyRunning: true)
        #expect(turnOff == nil)
    }

    @Test("Balanced curve midpoint produces exact expected value")
    func balancedMidpoint() {
        let curve = FanProfile.balanced.curve
        // At 62.5°C: position = (62.5-55)/(70-55) = 0.5, target = 0.5 * 0.60 = 0.30
        let atMid = curve.targetPercent(at: 62.5, fansCurrentlyRunning: true)
        #expect(atMid != nil)
        #expect(abs(atMid! - 0.30) < 0.001)
    }
}
