//
//  ProfileTests.swift
//  ThermalForge
//

import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Profiles")
struct ProfileTests {

    // MARK: - Built-in Profile Parameters

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

        // Balanced: 50-55-70°C, 60% max, ease-in, 8s trigger
        #expect(FanProfile.balanced.curve.startTemp == 55)
        #expect(FanProfile.balanced.curve.ceilingTemp == 70)
        #expect(FanProfile.balanced.curve.maxRPMPercent == 0.60)
        #expect(FanProfile.balanced.curve.curveShape == .easeIn)
        #expect(FanProfile.balanced.curve.sustainedTriggerSec == 8)
        #expect(FanProfile.balanced.curve.instantEngage == false)

        // Performance: 50-55-65°C, 85% max, linear, 4s trigger
        #expect(FanProfile.performance.curve.startTemp == 55)
        #expect(FanProfile.performance.curve.ceilingTemp == 65)
        #expect(FanProfile.performance.curve.maxRPMPercent == 0.85)
        #expect(FanProfile.performance.curve.curveShape == .linear)
        #expect(FanProfile.performance.curve.sustainedTriggerSec == 4)
        #expect(FanProfile.performance.curve.instantEngage == false)

        // Max: 50-65-65°C, 100%, instant engage, 5s trigger
        #expect(FanProfile.max.curve.startTemp == 65)
        #expect(FanProfile.max.curve.ceilingTemp == 65)
        #expect(FanProfile.max.curve.maxRPMPercent == 1.0)
        #expect(FanProfile.max.curve.instantEngage == true)
        #expect(FanProfile.max.curve.sustainedTriggerSec == 5)
        #expect(FanProfile.max.curve.alwaysOn == false)

        // Smart: 50-53-85°C, 100%, S-curve, 6s trigger
        #expect(FanProfile.smart.curve.startTemp == 53)
        #expect(FanProfile.smart.curve.ceilingTemp == 85)
        #expect(FanProfile.smart.curve.maxRPMPercent == 1.0)
        #expect(FanProfile.smart.curve.curveShape == .sCurve)
        #expect(FanProfile.smart.curve.sustainedTriggerSec == 6)
    }

    @Test("Five built-in profiles exist")
    func builtInCount() {
        #expect(FanProfile.builtIn.count == 5)
        let ids = FanProfile.builtIn.map(\.id)
        #expect(ids.contains("silent"))
        #expect(ids.contains("balanced"))
        #expect(ids.contains("performance"))
        #expect(ids.contains("max"))
        #expect(ids.contains("smart"))
    }

    @Test("Profile round-trips through JSON")
    func jsonRoundTrip() throws {
        for profile in FanProfile.builtIn {
            let data = try JSONEncoder().encode(profile)
            let decoded = try JSONDecoder().decode(FanProfile.self, from: data)
            #expect(decoded == profile, "Round-trip failed for \(profile.name)")
        }
        let smartData = try JSONEncoder().encode(FanProfile.smart)
        let smartDecoded = try JSONDecoder().decode(FanProfile.self, from: smartData)
        #expect(smartDecoded == FanProfile.smart)
    }

    @Test("Custom profile saves and loads")
    func saveLoad() throws {
        let custom = FanProfile(
            id: "test_custom",
            name: "Test Custom",
            curve: FanProfile.Curve(stopTemp: 45, startTemp: 55, ceilingTemp: 65,
                                    maxRPMPercent: 0.50, curveShape: .easeOut,
                                    rampUpPerSec: 0.08, sustainedTriggerSec: 3)
        )

        try custom.save()

        let loaded = FanProfile.loadAll()
        let found = loaded.first { $0.id == "test_custom" }
        #expect(found != nil)
        #expect(found?.curve.startTemp == 55)
        #expect(found?.curve.maxRPMPercent == 0.50)
        #expect(found?.curve.curveShape == .easeOut)
        #expect(found?.curve.rampUpPerSec == 0.08)
        #expect(found?.curve.sustainedTriggerSec == 3)

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

    // MARK: - Curve Shape Behavior

    @Test("Balanced ease-in curve: quiet at low temps, ramps harder at high")
    func balancedEaseIn() {
        let curve = FanProfile.balanced.curve

        // Below stop (50°C): fans off
        #expect(curve.targetPercent(at: 45, fansCurrentlyRunning: false) == nil)

        // At start (55°C): position=0, easeIn=0² → 0 (at minimum)
        let atStart = curve.targetPercent(at: 55, fansCurrentlyRunning: false)
        #expect(atStart != nil)
        #expect(atStart! >= 0)

        // At ceiling (70°C): should be at maxRPMPercent regardless of shape
        let atCeiling = curve.targetPercent(at: 70, fansCurrentlyRunning: true)
        #expect(atCeiling == 0.60)

        // Midpoint (62.5°C): position = 0.5, easeIn = 0.25, target = 0.25 * 0.60 = 0.15
        let atMid = curve.targetPercent(at: 62.5, fansCurrentlyRunning: true)
        #expect(atMid != nil)
        #expect(abs(atMid! - 0.15) < 0.001)

        // Compare: easeIn at midpoint (0.15) < linear midpoint (0.30)
        // This confirms easeIn is quieter at low temps
    }

    @Test("Performance linear curve: direct proportional response")
    func performanceLinear() {
        let curve = FanProfile.performance.curve

        // At ceiling (65°C): 85%
        #expect(curve.targetPercent(at: 65, fansCurrentlyRunning: true) == 0.85)

        // Midpoint (60°C): position = 0.5, linear = 0.5, target = 0.5 * 0.85 = 0.425
        let atMid = curve.targetPercent(at: 60, fansCurrentlyRunning: true)
        #expect(atMid != nil)
        #expect(abs(atMid! - 0.425) < 0.001)
    }

    @Test("Max profile: instant engage returns maxRPMPercent immediately")
    func maxInstantEngage() {
        let curve = FanProfile.max.curve

        // Below stop (50°C): fans off
        #expect(curve.targetPercent(at: 45, fansCurrentlyRunning: false) == nil)

        // In hysteresis (50-65°C), fans not running: stay off
        #expect(curve.targetPercent(at: 60, fansCurrentlyRunning: false) == nil)

        // In hysteresis (50-65°C), fans running: keep at minimum
        let hyst = curve.targetPercent(at: 60, fansCurrentlyRunning: true)
        #expect(hyst != nil)
        #expect(hyst! == 0.001)

        // At start (65°C): instantEngage → returns 1.0 immediately (no proportional curve)
        let atStart = curve.targetPercent(at: 65, fansCurrentlyRunning: false)
        #expect(atStart == 1.0)

        // Above start: still 1.0
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
        #expect(smart.curve.curveShape == .sCurve)
        #expect(smart.curve.handsOff == false)
        #expect(smart.curve.alwaysOn == false)
        #expect(smart.curve.instantEngage == false)
        #expect(smart.curve.sustainedTriggerSec == 6)
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

    // MARK: - Curve Shape Math

    @Test("S-curve shape produces correct values at key positions")
    func sCurveShape() {
        // Using a custom curve to test S-curve shape directly
        // stopTemp well below startTemp to avoid hysteresis interference
        let curve = FanProfile.Curve(stopTemp: -10, startTemp: 0, ceilingTemp: 100,
                                     maxRPMPercent: 1.0, curveShape: .sCurve)

        // At 0 (start): S-curve position=0, shaped=0
        let at0 = curve.targetPercent(at: 0, fansCurrentlyRunning: true)
        #expect(at0 != nil)
        #expect(abs(at0! - 0) < 0.001)

        // At 50 (midpoint): position=0.5, S-curve = 0.5²(3-2*0.5) = 0.25 * 2 = 0.5
        let at50 = curve.targetPercent(at: 50, fansCurrentlyRunning: true)
        #expect(at50 != nil)
        #expect(abs(at50! - 0.5) < 0.001)

        // At 100 (ceiling): capped at maxRPMPercent = 1.0
        let at100 = curve.targetPercent(at: 100, fansCurrentlyRunning: true)
        #expect(at100 == 1.0)
    }

    @Test("Ease-out curve is faster at low temps than ease-in")
    func easeOutVsEaseIn() {
        let easeOutCurve = FanProfile.Curve(stopTemp: -10, startTemp: 0, ceilingTemp: 100,
                                            maxRPMPercent: 1.0, curveShape: .easeOut)
        let easeInCurve = FanProfile.Curve(stopTemp: -10, startTemp: 0, ceilingTemp: 100,
                                           maxRPMPercent: 1.0, curveShape: .easeIn)

        // At position 0.25 (25°C):
        // easeOut = √0.25 = 0.5
        // easeIn = 0.25² = 0.0625
        let easeOutVal = easeOutCurve.targetPercent(at: 25, fansCurrentlyRunning: true)!
        let easeInVal = easeInCurve.targetPercent(at: 25, fansCurrentlyRunning: true)!

        #expect(easeOutVal > easeInVal) // easeOut is faster at low positions
        #expect(abs(easeOutVal - 0.5) < 0.001)
        #expect(abs(easeInVal - 0.0625) < 0.001)
    }

    // MARK: - Per-Profile Ramp Rates

    @Test("Each profile has distinct ramp rates matching its personality")
    func perProfileRampRates() {
        // Balanced: gentle
        #expect(FanProfile.balanced.curve.rampUpPerSec == 0.05)
        #expect(FanProfile.balanced.curve.rampDownPerSec == 0.025)

        // Performance: 2× Balanced ramp-up
        #expect(FanProfile.performance.curve.rampUpPerSec == 0.10)
        #expect(FanProfile.performance.curve.rampDownPerSec == 0.04)

        // Max: instant engage (rampUp ignored), gentle ramp-down
        #expect(FanProfile.max.curve.instantEngage == true)
        #expect(FanProfile.max.curve.rampDownPerSec == 0.025)

        // Smart: same base as Balanced (adaptive logic modifies at runtime)
        #expect(FanProfile.smart.curve.rampUpPerSec == 0.05)
        #expect(FanProfile.smart.curve.rampDownPerSec == 0.025)
    }

    @Test("Per-profile sustained trigger durations")
    func perProfileSustainedTriggers() {
        #expect(FanProfile.balanced.curve.sustainedTriggerSec == 8)     // Conservative
        #expect(FanProfile.performance.curve.sustainedTriggerSec == 4)  // Responsive
        #expect(FanProfile.max.curve.sustainedTriggerSec == 5)          // Attack dog threshold
        #expect(FanProfile.smart.curve.sustainedTriggerSec == 6)        // Proactive
    }
}
