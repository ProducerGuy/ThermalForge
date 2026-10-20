//
//  AnomalyGateTests.swift
//  ThermalForge
//

import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Anomaly gate")
struct AnomalyGateTests {

    private func date(_ seconds: Double) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    /// Evaluate away from the #expect macro: it captures the gate as an
    /// immutable copy, so the mutating call must run first.
    private func eval(_ gate: inout AnomalyGate, _ temp: Float, at seconds: Double) -> AnomalyGate.Event {
        gate.evaluate(temp: temp, at: date(seconds))
    }

    @Test("instant event fires when the 2s delta exceeds the threshold")
    func instantFires() {
        var gate = AnomalyGate()
        #expect(eval(&gate, 75, at: 0) == .none)
        #expect(eval(&gate, 82, at: 2) == .instant(from: 75, to: 82))
    }

    @Test("delta exactly at the threshold does not fire (strict >)")
    func thresholdStrict() {
        var gate = AnomalyGate()
        _ = eval(&gate, 75, at: 0)
        #expect(eval(&gate, 80, at: 2) == .none)
        #expect(eval(&gate, 75, at: 4) == .none) // exact -5 also quiet
    }

    @Test("cooldown suppresses the echo of threshold-edge oscillation")
    func cooldownSuppresses() {
        var gate = AnomalyGate()
        _ = eval(&gate, 75, at: 0)
        // First crossing reports.
        #expect(eval(&gate, 82, at: 2) == .instant(from: 75, to: 82))
        // The rebound crossing, 2s later, is inside the 60s cooldown: silent.
        #expect(eval(&gate, 76, at: 4) == .none)
        // Still silent at 59s.
        #expect(eval(&gate, 83, at: 59) == .none)
        // Past the cooldown, a real crossing reports again.
        #expect(eval(&gate, 90, at: 62) == .instant(from: 83, to: 90))
    }

    @Test("history keeps recording during cooldown — prev-tracking survives")
    func historyLivesThroughCooldown() {
        var gate = AnomalyGate()
        _ = eval(&gate, 75, at: 0)
        #expect(eval(&gate, 82, at: 2) == .instant(from: 75, to: 82))
        // Suppressed sample still becomes the new "previous".
        #expect(eval(&gate, 89, at: 4) == .none)
        // After the cooldown the instant tier compares against 89, not 82.
        #expect(eval(&gate, 96, at: 63) == .instant(from: 89, to: 96))
    }

    @Test("sustained event fires over the 30s window and resets it")
    func sustainedFiresAndResets() {
        var gate = AnomalyGate()
        // Fill the 15-sample window with a slowly rising ramp (no instant hits).
        for i in 0..<15 {
            #expect(eval(&gate, Float(50 + i), at: Double(i) * 2) == .none)
        }
        // +11 over the 30s-ago sample: sustained, not instant (+1 from prev).
        #expect(eval(&gate, 61, at: 30) == .sustained(from: 50, to: 61))
        // Window was cleared (prev now 61), but the just-reported sustained
        // event starts the cooldown: the next crossing is suppressed...
        #expect(eval(&gate, 68, at: 32) == .none)
        _ = eval(&gate, 75, at: 34)
        // ...until the cooldown lapses, and prev-tracking survived the reset.
        #expect(eval(&gate, 82, at: 94) == .instant(from: 75, to: 82))
    }

    @Test("rolling history caps at 15 samples")
    func historyCaps() {
        var gate = AnomalyGate()
        for i in 0..<20 {
            _ = gate.evaluate(temp: Float(50 + i % 2), at: date(Double(i) * 2))
        }
        #expect(gate.history.count == 15)
    }
}
