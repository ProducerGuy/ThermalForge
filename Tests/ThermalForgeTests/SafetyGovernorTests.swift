//
//  SafetyGovernorTests.swift
//  ThermalForge
//
//  The rebuilt thermal safety floor, tested hardware-free: pressure-primary
//  tripping, per-class thresholds with seconds-based persistence, second-highest
//  hotspot semantics (for trips AND clears), sanitized readings, re-trip backoff,
//  and latch clearing. Calibrated against a MacBook Pro 14" M4 Max (Mac16,6) on
//  macOS 27, where hotspot-class keys legitimately read up to ~113°C under
//  sustained load with macOS itself nominal (fans at minimum, no throttling).
//

import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Safety governor")
struct SafetyGovernorTests {

    private func samples(hotspot: [Float] = [], structure: [Float] = [], battery: [Float] = []) -> [SafetySample] {
        var out: [SafetySample] = []
        for (i, c) in hotspot.enumerated() {
            out.append(SafetySample(key: "Tp\(i)", celsius: c, sensorClass: .hotspot))
        }
        for (i, c) in structure.enumerated() {
            out.append(SafetySample(key: "TS\(i)", celsius: c, sensorClass: .structure))
        }
        for (i, c) in battery.enumerated() {
            out.append(SafetySample(key: "TB\(i)", celsius: c, sensorClass: .battery))
        }
        return out
    }

    @discardableResult
    private func step(_ g: inout SafetyGovernor, seconds: Double, samples: [SafetySample],
                      pressure: ThermalPressureLevel = .nominal,
                      holdActive: Bool = true) -> SafetyGovernor.Action {
        g.evaluate(samples: samples, pressure: pressure, holdActive: holdActive, elapsed: seconds)
    }

    @Test("hotspots at 96-113.5°C for a full minute do NOT trip — the M4 laptop case")
    func hotspotRealWorldNoTrip() {
        var g = SafetyGovernor()
        for _ in 0..<60 {
            step(&g, seconds: 1, samples: samples(hotspot: [96, 104, 113.5]))
        }
        #expect(!g.isLatched)
    }

    @Test("hotspot at 118°C trips, but only after the sustained window")
    func hotspotSustainedTrip() {
        var g = SafetyGovernor()
        for i in 0..<10 {
            let a = step(&g, seconds: 1, samples: samples(hotspot: [120, 118]))
            if i < 9 {
                #expect(a == .none)
            } else if case .engage = a {
                // expected
            } else {
                Issue.record("expected engage on sustained hotspot, got \(a)")
            }
        }
        #expect(g.isLatched)
    }

    @Test("a single glitchy key cannot trip — the second-highest reading counts")
    func secondHighestTrip() {
        var g = SafetyGovernor()
        for _ in 0..<30 {
            #expect(step(&g, seconds: 1, samples: samples(hotspot: [135, 80, 75])) == .none)
        }
    }

    @Test("a single glitchy key cannot block clearing either")
    func secondHighestClear() {
        var g = SafetyGovernor(isLatched: true)
        for _ in 0..<31 {
            step(&g, seconds: 1, samples: samples(hotspot: [130, 80]))
        }
        #expect(!g.isLatched)
    }

    @Test("serious/critical pressure trips immediately — even with no readable sensors")
    func pressureImmediate() {
        var g = SafetyGovernor()
        if case .engage = step(&g, seconds: 1, samples: [], pressure: .serious) {
            // expected
        } else {
            Issue.record("expected instant engage on serious pressure")
        }
        var h = SafetyGovernor()
        if case .engage = step(&h, seconds: 1, samples: samples(hotspot: [70]), pressure: .critical) {
            // expected
        } else {
            Issue.record("expected instant engage on critical pressure")
        }
    }

    @Test("fair pressure trips only after its window")
    func fairSustained() {
        var g = SafetyGovernor()
        for i in 0..<30 {
            let a = step(&g, seconds: 1, samples: samples(hotspot: [70]), pressure: .fair)
            if i < 29 {
                #expect(a == .none)
            } else if case .engage = a {
                // expected
            } else {
                Issue.record("expected engage on sustained fair pressure, got \(a)")
            }
        }
    }

    @Test("structure and battery classes use their own slower thresholds")
    func structureAndBattery() {
        var g = SafetyGovernor()
        for _ in 0..<31 {
            #expect(step(&g, seconds: 1, samples: samples(hotspot: [70], structure: [90], battery: [45])) == .none)
        }

        var s = SafetyGovernor()
        var engaged = false
        for _ in 0..<30 {
            if case .engage = step(&s, seconds: 1, samples: samples(hotspot: [70], structure: [96])) {
                engaged = true
            }
        }
        #expect(engaged)

        var b = SafetyGovernor()
        var engagedBattery = false
        for _ in 0..<60 {
            if case .engage = step(&b, seconds: 1, samples: samples(hotspot: [70], battery: [51])) {
                engagedBattery = true
            }
        }
        #expect(engagedBattery)
    }

    @Test("no hold → nothing runs, nothing latches")
    func inactiveNoHold() {
        var g = SafetyGovernor()
        for _ in 0..<50 {
            #expect(step(&g, seconds: 1, samples: samples(hotspot: [130]),
                         pressure: .serious, holdActive: false) == .none)
        }
        #expect(!g.isLatched)
    }

    @Test("latch clears only at nominal pressure, sustained, with every class cooled")
    func latchClear() {
        var g = SafetyGovernor(isLatched: true)
        // Fair pressure does NOT clear, even cooled.
        for _ in 0..<60 {
            #expect(step(&g, seconds: 1, samples: samples(hotspot: [80]), pressure: .fair) == .none)
        }
        #expect(g.isLatched)
        // Still hot at nominal: no clear.
        for _ in 0..<60 {
            #expect(step(&g, seconds: 1, samples: samples(hotspot: [110])) == .none)
        }
        #expect(g.isLatched)
        // Cool + nominal, sustained → restore.
        var sawRestore = false
        for _ in 0..<31 {
            if case .restore = step(&g, seconds: 1, samples: samples(hotspot: [80])) {
                sawRestore = true
            }
        }
        #expect(sawRestore)
        #expect(!g.isLatched)
    }

    @Test("garbage readings are sanitized; an all-garbage hold behaves as blind")
    func sanitize() {
        var g = SafetyGovernor()
        for _ in 0..<60 {
            step(&g, seconds: 1, samples: samples(hotspot: [0, -4, 999, 80]))
        }
        #expect(!g.isLatched)

        var h = SafetyGovernor()
        var blindTripped = false
        for i in 0..<6 {
            let a = step(&h, seconds: 1, samples: samples(hotspot: [0, -4, 999]))
            if i >= 4, case .engage = a { blindTripped = true }
        }
        #expect(blindTripped)
    }

    @Test("after repeated trips in the window, the governor stops cycling (stayAuto)")
    func retripBackoff() {
        var g = SafetyGovernor()
        var stayAutoSeen = false
        for round in 0..<3 {
            var engaged = false
            for _ in 0..<11 {
                if case .engage = step(&g, seconds: 1, samples: samples(hotspot: [120, 118])) {
                    engaged = true
                }
            }
            #expect(engaged)

            var finalAction: SafetyGovernor.Action = .none
            for _ in 0..<31 {
                let a = step(&g, seconds: 1, samples: samples(hotspot: [80]))
                if a != .none { finalAction = a }
            }
            if round < 2 {
                if case .restore = finalAction {
                    // expected
                } else {
                    Issue.record("expected restore in round \(round), got \(finalAction)")
                }
            } else {
                if case .stayAuto = finalAction {
                    stayAutoSeen = true
                } else {
                    Issue.record("expected stayAuto in final round, got \(finalAction)")
                }
            }
        }
        #expect(stayAutoSeen)
    }

    @Test("pressure level maps and compares as a ladder")
    func pressureLadder() {
        #expect(ThermalPressureLevel(.nominal) == .nominal)
        #expect(ThermalPressureLevel(.fair) > ThermalPressureLevel(.nominal))
        #expect(ThermalPressureLevel(.serious) > ThermalPressureLevel(.fair))
        #expect(ThermalPressureLevel(.critical) > ThermalPressureLevel(.serious))
    }
}
