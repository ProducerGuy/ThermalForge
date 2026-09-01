//
//  ProfileTests.swift
//  ThermalForge
//

import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Profiles")
struct ProfileTests {

    // MARK: - Launch restore resolution

    @Test("selectable(id:) resolves known profiles, including Smart, and falls back to Silent")
    func selectableResolution() {
        // Every built-in resolves to itself.
        #expect(FanProfile.selectable(id: "silent").id == "silent")
        #expect(FanProfile.selectable(id: "balanced").id == "balanced")
        #expect(FanProfile.selectable(id: "performance").id == "performance")
        #expect(FanProfile.selectable(id: "max").id == "max")
        // Smart resolves even though it isn't in `builtIn`.
        #expect(FanProfile.selectable(id: "smart").id == "smart")
        // Unknown id (a profile removed in a future version) and nil both fall to Silent.
        #expect(FanProfile.selectable(id: "does-not-exist").id == "silent")
        #expect(FanProfile.selectable(id: nil).id == "silent")
    }

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
        // Also test Smart (not in builtIn but important)
        let smartData = try JSONEncoder().encode(FanProfile.smart)
        let smartDecoded = try JSONDecoder().decode(FanProfile.self, from: smartData)
        #expect(smartDecoded == FanProfile.smart)
    }

    /// A throwaway profiles directory. Tests never touch the real one — a user with a
    /// hand-written balanced.json would otherwise have it overwritten by `swift test`.
    private static func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ThermalForgeTests-\(UUID().uuidString)")
    }

    @Test("Custom profile saves and loads")
    func saveLoad() throws {
        let dir = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let custom = FanProfile(
            id: "test_custom",
            name: "Test Custom",
            curve: FanProfile.Curve(stopTemp: 45, startTemp: 55, ceilingTemp: 65,
                                    maxRPMPercent: 0.50, curveShape: .easeOut,
                                    rampUpPerSec: 0.08, sustainedTriggerSec: 3)
        )

        try custom.save(to: dir)

        let loaded = FanProfile.loadAll(from: dir)
        let found = loaded.first { $0.id == "test_custom" }
        #expect(found != nil)
        #expect(found?.curve.startTemp == 55)
        #expect(found?.curve.maxRPMPercent == 0.50)
        #expect(found?.curve.curveShape == .easeOut)
        #expect(found?.curve.rampUpPerSec == 0.08)
        #expect(found?.curve.sustainedTriggerSec == 3)
    }

    @Test("A missing profiles directory yields the built-ins")
    func loadAllWithNoDirectory() {
        #expect(FanProfile.loadAll(from: Self.scratchDirectory()) == FanProfile.builtIn)
    }

    @Test("A custom profile sorts by loudness, not onto the end of the list")
    func customProfilesSortByCeiling() throws {
        let dir = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A 45% cap is quieter than Balanced's 60%, so it belongs between Silent and
        // Balanced. Appending would put it after Max, reading as the most aggressive entry.
        try FanProfile(
            id: "test_low_cap", name: "Test Low Cap",
            curve: FanProfile.Curve(startTemp: 62, ceilingTemp: 85, maxRPMPercent: 0.45,
                                    curveShape: .easeIn)
        ).save(to: dir)

        #expect(FanProfile.loadAll(from: dir).map(\.id)
            == ["silent", "test_low_cap", "balanced", "performance", "max"])
    }

    @Test("Ordering leaves the built-in list exactly as shipped")
    func builtInOrderUnchanged() {
        #expect(FanProfile.orderedByCeiling(FanProfile.builtIn) == FanProfile.builtIn)
    }

    @Test("Profiles sharing a cap keep insertion order, so a built-in stays ahead")
    func equalCeilingsKeepInsertionOrder() {
        let sameAsBalanced = FanProfile(
            id: "test_tie", name: "Test Tie",
            curve: FanProfile.Curve(startTemp: 58, ceilingTemp: 72, maxRPMPercent: 0.60)
        )
        let ordered = FanProfile.orderedByCeiling(FanProfile.builtIn + [sameAsBalanced])
        #expect(ordered.map(\.id) == ["silent", "balanced", "test_tie", "performance", "max"])
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

    // MARK: - Curve Validation

    @Test("Every profile offered in the picker passes the validation applied to loaded ones")
    func builtInProfilesValidate() {
        // Smart is excluded deliberately: its 3°C band is under the project's 5°C rule, and
        // it never goes through this path because `smart` is a reserved id on disk.
        for profile in FanProfile.builtIn {
            #expect(profile.curve.validationError == nil,
                    "\(profile.id): \(profile.curve.validationError ?? "")")
        }
    }

    @Test("Nonsensical curves are rejected")
    func invalidCurvesAreRejected() {
        // Start at or below stop: the hysteresis band is empty or inverted.
        #expect(FanProfile.Curve(stopTemp: 60, startTemp: 55).validationError != nil)
        #expect(FanProfile.Curve(stopTemp: 55, startTemp: 55).validationError != nil)
        // Ceiling below start: the proportional zone runs backwards.
        #expect(FanProfile.Curve(startTemp: 70, ceilingTemp: 60).validationError != nil)
        // Ceiling equal to start without instantEngage: the curve collapses to a step.
        #expect(FanProfile.Curve(startTemp: 65, ceilingTemp: 65).validationError != nil)
        // Speeds and rates outside their ranges.
        #expect(FanProfile.Curve(maxRPMPercent: 0).validationError != nil)
        #expect(FanProfile.Curve(maxRPMPercent: 1.5).validationError != nil)
        #expect(FanProfile.Curve(rampUpPerSec: 0).validationError != nil)
        #expect(FanProfile.Curve(sustainedTriggerSec: 400).validationError != nil)
        #expect(FanProfile.Curve(sustainedTriggerSec: -1).validationError != nil)
        // Engaging above the safety threshold would never fire before the override does.
        #expect(FanProfile.Curve(startTemp: 97, ceilingTemp: 99).validationError != nil)
        // A ceiling past the override is unreachable.
        #expect(FanProfile.Curve(startTemp: 60, ceilingTemp: 120).validationError != nil)
        // alwaysOn never hands the fans back to auto.
        #expect(FanProfile.Curve(alwaysOn: true).validationError != nil)

        // Max's ceiling == start is allowed: instant engage has no proportional zone.
        #expect(FanProfile.Curve(stopTemp: 50, startTemp: 65, ceilingTemp: 65,
                                 maxRPMPercent: 1.0, instantEngage: true).validationError == nil)
        // handsOff short-circuits: Silent controls nothing, so its thresholds are inert.
        #expect(FanProfile.Curve(stopTemp: 99, startTemp: 1, handsOff: true)
            .validationError == nil)
    }

    @Test("Validation boundaries are inclusive where the message says they are")
    func validationBoundaries() {
        // Exactly the project's 5°C hysteresis band: allowed.
        #expect(FanProfile.Curve(stopTemp: 50, startTemp: 55).validationError == nil)
        // A whisker under it: rejected.
        #expect(FanProfile.Curve(stopTemp: 50, startTemp: 54.9).validationError != nil)
        // Exactly the safety threshold: startTemp rejected, ceilingTemp allowed.
        #expect(FanProfile.Curve(startTemp: 95, ceilingTemp: 99).validationError != nil)
        #expect(FanProfile.Curve(startTemp: 88, ceilingTemp: 95).validationError == nil)
        // Full speed and the trigger ceiling are both legal.
        #expect(FanProfile.Curve(maxRPMPercent: 1.0).validationError == nil)
        #expect(FanProfile.Curve(sustainedTriggerSec: 300).validationError == nil)
        #expect(FanProfile.Curve(sustainedTriggerSec: 301).validationError != nil)
    }

    @Test("A malformed profile file is skipped, leaving the built-in in place")
    func malformedProfileIsSkipped() throws {
        let dir = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // ceilingTemp below startTemp — the fan would never reach its cap.
        try FanProfile(
            id: "performance",
            name: "Performance",
            curve: FanProfile.Curve(stopTemp: 50, startTemp: 80, ceilingTemp: 60)
        ).save(to: dir)

        let performance = FanProfile.loadAll(from: dir).first { $0.id == "performance" }
        #expect(performance?.curve.startTemp == 55)   // shipped value, not the broken 80
        #expect(performance?.curve.ceilingTemp == 65)
    }

    @Test("Undecodable JSON is skipped without taking the rest of the directory with it")
    func undecodableFileIsSkipped() throws {
        let dir = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let good = FanProfile(id: "test_good", name: "Good",
                              curve: FanProfile.Curve(startTemp: 62, ceilingTemp: 85,
                                                      maxRPMPercent: 0.45))
        try good.save(to: dir)
        // Partial JSON: Curve's properties are non-optional, so this cannot decode.
        try Data(#"{"id":"test_partial","name":"Partial","curve":{"startTemp":62}}"#.utf8)
            .write(to: dir.appendingPathComponent("test_partial.json"))

        let loaded = FanProfile.loadAll(from: dir)
        #expect(loaded.contains { $0.id == "test_good" })
        #expect(!loaded.contains { $0.id == "test_partial" })
    }

    @Test("A file claiming the reserved smart id is rejected, not offered alongside Smart")
    func reservedIDIsRejected() throws {
        let dir = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        // ThermalMonitor dispatches "smart" to its own adaptive path, which reads almost
        // none of this curve — offering it would be a profile that silently doesn't apply.
        try FanProfile(id: "smart", name: "My Smart",
                       curve: FanProfile.Curve(startTemp: 70, ceilingTemp: 90,
                                               maxRPMPercent: 0.5)).save(to: dir)

        let loaded = FanProfile.loadAll(from: dir)
        #expect(!loaded.contains { $0.id == "smart" })
    }

    // MARK: - Custom Profile Discovery

    @Test("selectable(id:from:) restores a custom profile the user had selected")
    func selectableFromCustomList() {
        let custom = FanProfile(
            id: "test_custom_profile",
            name: "Test Custom Profile",
            curve: FanProfile.Curve(startTemp: 62, ceilingTemp: 85, maxRPMPercent: 0.45)
        )
        let available = FanProfile.builtIn + [.smart, custom]

        #expect(FanProfile.selectable(id: "test_custom_profile", from: available).id == "test_custom_profile")
        #expect(FanProfile.selectable(id: "smart", from: available).id == "smart")
        // An id that vanished (profile deleted between launches) falls back to Silent.
        #expect(FanProfile.selectable(id: "test_custom_profile", from: FanProfile.builtIn).id == "silent")
        #expect(FanProfile.selectable(id: nil, from: available).id == "silent")
    }

    @Test("A custom profile overrides a built-in with the same id")
    func customOverridesBuiltIn() throws {
        let dir = Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try FanProfile(
            id: "balanced",
            name: "Balanced",
            curve: FanProfile.Curve(startTemp: 62, ceilingTemp: 85, maxRPMPercent: 0.45,
                                    curveShape: .easeIn)
        ).save(to: dir)

        let loaded = FanProfile.loadAll(from: dir)
        // Still exactly one "balanced" — the custom file replaces it, not appends.
        #expect(loaded.filter { $0.id == "balanced" }.count == 1)
        let balanced = loaded.first { $0.id == "balanced" }
        #expect(balanced?.curve.startTemp == 62)
        #expect(balanced?.curve.maxRPMPercent == 0.45)
    }
}
