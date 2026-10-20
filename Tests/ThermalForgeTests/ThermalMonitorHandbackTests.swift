//
//  ThermalMonitorHandbackTests.swift
//  ThermalForge
//
//  Hands-off handback is CONFIRMED against the hardware fan mode, not assumed
//  from bookkeeping: a ramp write already in flight when the profile switched
//  can land at the daemon AFTER the switch's resetAuto and re-pin the fans in
//  manual — both BEFORE the first confirmation tick and after the hardware has
//  briefly read auto (the 2026-10-10 race took the second shape). The armed
//  handback watch must retry resetAuto until the hardware confirms auto, then
//  settle; and it must EXPIRE, so a hands-off monitor never permanently fights
//  a dead daemon or an external tool holding manual.
//

import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("ThermalMonitor hands-off handback")
struct ThermalMonitorHandbackTests {

    /// Thread-safe command recorder — ticks run on the monitor's queue while
    /// assertions read from the test thread.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _commands: [FanCommand] = []

        var commands: [FanCommand] {
            lock.lock(); defer { lock.unlock() }
            return _commands
        }

        func record(_ c: FanCommand) {
            lock.lock(); defer { lock.unlock() }
            _commands.append(c)
        }

        var resetAutoCount: Int {
            commands.filter { $0 == .resetAuto }.count
        }
    }

    /// Scripted status source: one fan whose mode the test flips between
    /// manual (a hold is pinning it) and auto (handed back to Apple).
    final class StatusScript: @unchecked Sendable {
        private let lock = NSLock()
        private var _mode: String
        private let temp: Float

        init(mode: String = "manual", temp: Float = 85) {
            _mode = mode
            self.temp = temp
        }

        var mode: String {
            get { lock.lock(); defer { lock.unlock() }; return _mode }
            set { lock.lock(); defer { lock.unlock() }; _mode = newValue }
        }

        var status: ThermalStatus {
            ThermalStatus(
                fans: [.init(index: 0, actualRPM: 4024, targetRPM: 4024,
                             minRPM: 2317, maxRPM: 7826, mode: mode)],
                temperatures: ["TC0p": temp]
            )
        }
    }

    private func makeMonitor(profile: FanProfile, script: StatusScript,
                             rec: Recorder) -> ThermalMonitor {
        let m = ThermalMonitor(profile: profile, readStatus: { script.status })
        m.onFanCommand = { rec.record($0) }
        return m
    }

    /// Run one tick ON the monitor's queue (where tick() is designed to run),
    /// which also acts as a barrier behind any queued switch/watch arm.
    private func tick(_ m: ThermalMonitor) {
        m.queue.sync { m.tick() }
    }

    /// Balanced profile driven past its 8-second sustained trigger, fans
    /// running: the pre-switch state of the race (a ramp is active, the
    /// monitor believes it owns the fans).
    private func rampThenSwitchToSilent(_ m: ThermalMonitor, rec: Recorder) {
        for _ in 0..<85 { tick(m) }          // 80 ticks = balanced's sustained window
        #expect(rec.commands.contains { if case .setRPM = $0 { true } else { false } })
        m.switchProfile(.silent)
        m.armHandbackWatch()               // what selectProfile does on a switch
        m.queue.sync {}                    // barrier: let both land
    }

    @Test("re-pin BEFORE the first hands-off tick: watch retries resetAuto until the hardware confirms auto")
    func repinBeforeConfirmIsHealed() {
        let script = StatusScript()          // manual — the late write already landed
        let rec = Recorder()
        let m = makeMonitor(profile: .balanced, script: script, rec: rec)

        rampThenSwitchToSilent(m, rec: rec)

        // Retries are rate-limited to one per handsOffRetryCadence ticks; drive
        // enough ticks to cross at least one retry boundary.
        let before = rec.resetAutoCount
        for _ in 0..<(ThermalMonitor.handsOffRetryCadence * 2 + 2) { tick(m) }
        let retried = rec.resetAutoCount - before
        #expect(retried >= 1)
        #expect(retried <= 3)                // rate-limited, not hammered

        // The retry landed: hardware reads auto — the loop settles and then
        // never sends anything again.
        script.mode = "auto"
        for _ in 0..<3 { tick(m) }
        let settled = rec.commands.count
        for _ in 0..<5 { tick(m) }
        #expect(rec.commands.count == settled)
    }

    @Test("re-pin AFTER the hardware confirmed auto: the still-armed watch catches it")
    func repinAfterConfirmIsHealed() {
        let script = StatusScript()
        let rec = Recorder()
        let m = makeMonitor(profile: .balanced, script: script, rec: rec)

        rampThenSwitchToSilent(m, rec: rec)
        script.mode = "auto"                 // the switch's resetAuto landed fine
        tick(m)                              // hardware-confirmed settle, no send
        let settled = rec.commands.count
        #expect(rec.resetAutoCount == 0)

        // The late ramp write lands NOW — after the confirmed auto. The watch
        // is still armed and must correct the re-pin.
        script.mode = "manual"
        for _ in 0..<(ThermalMonitor.handsOffRetryCadence + 2) { tick(m) }
        #expect(rec.resetAutoCount >= 1)

        script.mode = "auto"                 // correction landed — settle again
        for _ in 0..<3 { tick(m) }
        let settledAgain = rec.commands.count
        for _ in 0..<5 { tick(m) }
        #expect(rec.commands.count == settledAgain)
    }

    @Test("clean handback: hardware already auto — no retry, state settles, nothing sent")
    func cleanHandbackSettlesImmediately() {
        let script = StatusScript()
        let rec = Recorder()
        let m = makeMonitor(profile: .balanced, script: script, rec: rec)

        rampThenSwitchToSilent(m, rec: rec)
        script.mode = "auto"

        for _ in 0..<6 { tick(m) }           // confirms and settles on the first
        #expect(rec.resetAutoCount == 0)     // no redundant resetAuto
    }

    @Test("idle hands-off (never controlled) never sends anything — even in manual")
    func idleSilentStaysQuiet() {
        // E.g. an external tool holds the fans manual; a Silent ThermalForge
        // that never controlled them (and never armed a watch) must not fight it.
        let script = StatusScript(mode: "manual")
        let rec = Recorder()
        let m = makeMonitor(profile: .silent, script: script, rec: rec)

        for _ in 0..<15 { tick(m) }
        #expect(rec.commands.isEmpty)
    }

    @Test("the handback watch is bounded: retries stop when it expires")
    func watchExpiresAndStopsRetrying() {
        let script = StatusScript()          // manual forever — daemon dead
        let rec = Recorder()
        let m = makeMonitor(profile: .balanced, script: script, rec: rec)

        rampThenSwitchToSilent(m, rec: rec)

        // Default window is 10s = 100 ticks at 100ms; at 1 Hz that is ~10
        // retries. Run PAST the window, then prove nothing more is sent.
        for _ in 0..<110 { tick(m) }
        let expired = rec.resetAutoCount
        #expect(expired >= 8 && expired <= 12)   // retried through the window…
        for _ in 0..<30 { tick(m) }
        #expect(rec.resetAutoCount == expired)   // …and then stopped
    }
}
