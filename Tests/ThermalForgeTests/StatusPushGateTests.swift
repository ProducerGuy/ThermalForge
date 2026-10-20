//
//  StatusPushGateTests.swift
//  ThermalForge
//

import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Status push gate")
struct StatusPushGateTests {

    /// Evaluate away from the #expect macro: it captures the gate as an
    /// immutable copy, so the mutating call must run first.
    private func push(_ gate: inout StatusPushGate, tick: Int,
                      profileID: String, state: MonitorState) -> Bool {
        gate.shouldPush(tick: tick, profileID: profileID, state: state)
    }

    @Test("first tick pushes")
    func firstPush() {
        var gate = StatusPushGate(intervalTicks: 10)
        #expect(push(&gate, tick: 0, profileID: "balanced", state: .idle))
    }

    @Test("pushes at the interval, not before")
    func cadence() {
        var gate = StatusPushGate(intervalTicks: 10)
        #expect(push(&gate, tick: 0, profileID: "balanced", state: .idle))
        for tick in 1...9 {
            #expect(!push(&gate, tick: tick, profileID: "balanced", state: .idle))
        }
        #expect(push(&gate, tick: 10, profileID: "balanced", state: .idle))
    }

    @Test("a profile change pushes immediately")
    func profileChange() {
        var gate = StatusPushGate(intervalTicks: 10)
        #expect(push(&gate, tick: 0, profileID: "balanced", state: .idle))
        #expect(!push(&gate, tick: 4, profileID: "balanced", state: .idle))
        #expect(push(&gate, tick: 5, profileID: "silent", state: .idle))
        // Fingerprint updated: same identity, next ticks quiet until cadence.
        // The immediate push reset the cadence anchor to tick 5.
        #expect(!push(&gate, tick: 6, profileID: "silent", state: .idle))
        #expect(!push(&gate, tick: 14, profileID: "silent", state: .idle))
        #expect(push(&gate, tick: 15, profileID: "silent", state: .idle))
    }

    @Test("a monitor-state change pushes immediately")
    func stateChange() {
        var gate = StatusPushGate(intervalTicks: 10)
        #expect(push(&gate, tick: 0, profileID: "balanced", state: .idle))
        #expect(!push(&gate, tick: 3, profileID: "balanced", state: .idle))
        #expect(push(&gate, tick: 4, profileID: "balanced", state: .safetyOverride))
        // Active carries the profile name — a different name is a change too.
        #expect(push(&gate, tick: 5, profileID: "balanced", state: .active(profileName: "Balanced")))
        #expect(!push(&gate, tick: 6, profileID: "balanced", state: .active(profileName: "Balanced")))
    }
}
