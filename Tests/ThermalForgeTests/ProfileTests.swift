//
//  ProfileTests.swift
//  ThermalForge
//

import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Profiles")
struct ProfileTests {

    @Test("Built-in profiles have correct thresholds")
    func builtInThresholds() {
        #expect(FanProfile.silent.triggers.cpuTemp == nil)
        #expect(FanProfile.silent.fanBehavior.mode == .auto)

        #expect(FanProfile.balanced.triggers.cpuTemp == 70)
        #expect(FanProfile.balanced.triggers.gpuTemp == 65)
        #expect(FanProfile.balanced.fanBehavior.rpmPercent == 0.60)

        #expect(FanProfile.performance.triggers.cpuTemp == 80)
        #expect(FanProfile.performance.triggers.gpuTemp == 75)
        #expect(FanProfile.performance.triggers.memPressure == 70)
        #expect(FanProfile.performance.fanBehavior.rpmPercent == 0.85)

        #expect(FanProfile.max.fanBehavior.rpmPercent == 1.0)
        #expect(FanProfile.max.fanBehavior.mode == .manual)
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
            triggers: FanProfile.Triggers(cpuTemp: 60, gpuTemp: 55),
            fanBehavior: FanProfile.FanBehavior(mode: .manual, rpmPercent: 0.50)
        )

        try custom.save()

        let loaded = FanProfile.loadAll()
        let found = loaded.first { $0.id == "test_custom" }
        #expect(found != nil)
        #expect(found?.triggers.cpuTemp == 60)
        #expect(found?.fanBehavior.rpmPercent == 0.50)

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
}
