//
//  FanOffGateTests.swift
//  ThermalForge
//
//  Client-side fans-off decision, tested hardware-free via the extracted
//  gate: a momentary dip below stopTemp HOLDS minimum instead of releasing,
//  and the release to Apple auto needs cold sustained for the full window.
//  Regression coverage for the stopTemp bang-bang observed in three days of
//  logs (2,182 releases, fans slamming 3000+→1300 RPM every 3-7 seconds on
//  idle-core sensor cliffs).
//

import Testing

@testable import ThermalForgeCore

@Suite("Client fans-off gate")
struct FanOffGateTests {

    @Test("momentary dip below stop holds minimum — never stops the fans")
    func momentaryDipHoldsMinimum() {
        var gate = FanOffGate()   // 5s window / 0.1s tick from FanProfile
        // Three seconds of cold: not yet.
        for _ in 0..<30 {
            #expect(gate.evaluate(temp: 49.5, stopTemp: 50) == .holdMinimum)
        }
        // The dip ends before the window: back to the curve, streak reset.
        #expect(gate.evaluate(temp: 52, stopTemp: 50) == .resume)
        #expect(gate.evaluate(temp: 58, stopTemp: 50) == .resume)
    }

    @Test("sustained cold releases — exactly at the sustained window")
    func sustainedColdReleases() {
        var gate = FanOffGate()
        // 49 ticks = 4.9s: hold.
        for _ in 0..<49 {
            #expect(gate.evaluate(temp: 50.0, stopTemp: 50) == .holdMinimum)
        }
        // Tick 50 = 5.0s: release.
        #expect(gate.evaluate(temp: 50.0, stopTemp: 50) == .release)
    }

    @Test("a warm tick anywhere in the window restarts the streak")
    func warmTickRestartsStreak() {
        var gate = FanOffGate()
        for _ in 0..<49 { _ = gate.evaluate(temp: 49.9, stopTemp: 50) }
        // The log signature: 49.9↔50.1 crossings every few seconds. One warm
        // tick and the whole streak is gone.
        #expect(gate.evaluate(temp: 50.1, stopTemp: 50) == .resume)
        for _ in 0..<49 {
            #expect(gate.evaluate(temp: 49.9, stopTemp: 50) == .holdMinimum)
        }
        #expect(gate.evaluate(temp: 49.9, stopTemp: 50) == .release)
    }

    @Test("after release, a new cold episode needs a fresh window")
    func releaseResetsStreak() {
        var gate = FanOffGate()
        // Cold for the full window: releases at tick 50.
        for _ in 0..<49 { _ = gate.evaluate(temp: 49, stopTemp: 50) }
        #expect(gate.evaluate(temp: 49, stopTemp: 50) == .release)
        // Still cold: counting starts over — not an instant re-release.
        #expect(gate.evaluate(temp: 49, stopTemp: 50) == .holdMinimum)
        // Ticks 2–49 of the new episode: still holding.
        for _ in 0..<47 {
            #expect(gate.evaluate(temp: 49, stopTemp: 50) == .holdMinimum)
        }
        #expect(gate.evaluate(temp: 49, stopTemp: 50) == .holdMinimum)
        // Tick 50 of the new episode: releases again.
        #expect(gate.evaluate(temp: 49, stopTemp: 50) == .release)
    }

    @Test("stop threshold is inclusive — 50.0 counts as cold")
    func stopThresholdInclusive() {
        var gate = FanOffGate()
        #expect(gate.evaluate(temp: 50.0, stopTemp: 50) == .holdMinimum)
        #expect(gate.evaluate(temp: 50.1, stopTemp: 50) == .resume)
    }

    @Test("window mirrors FanProfile, not hardcoded numbers")
    func windowMirrorsProfile() {
        let gate = FanOffGate()
        #expect(gate.sustainSeconds == FanProfile.stopSustainSeconds)
        #expect(gate.tickInterval == 0.1)
    }
}
