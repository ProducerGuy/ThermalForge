//
//  PowerModeTests.swift
//  ThermalForge
//
//  Step 1 verification of the power-mode protection layer:
//  - the pure decision function (thresholds, hysteresis, safe-direction rule)
//  - the controller loop against a stub backend (set/verify, failures,
//    external changes, key-absent, config updates)
//  - the pmset output parser (real captured output shape, lowpowermode trap)
//  - config persistence and clamping
//  - the new conservative ThermalStatus peak
//

import Foundation
import Testing

@testable import ThermalForgeCore

// MARK: - Stub backend

/// A scriptable pmset. `compliant` = the read-back reports what we just set
/// (the real pmset on the dev machines); `setFailure` simulates e.g. sudo
/// refusing without a TTY.
final class StubPowerModeBackend: PowerModeBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _readResult: PowerModeReadResult

    private(set) var setCalls: [PowerMode] = []
    var compliant: Bool
    var setFailure: String?

    init(reading: PowerModeReadResult = .mode(.high), compliant: Bool = true) {
        self._readResult = reading
        self.compliant = compliant
    }

    var readResultToReturn: PowerModeReadResult {
        get {
            lock.lock(); defer { lock.unlock() }
            return _readResult
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _readResult = newValue
        }
    }

    func readResult() -> PowerModeReadResult { readResultToReturn }

    func setMode(_ mode: PowerMode) throws {
        lock.lock()
        setCalls.append(mode)   // record the attempt even when it fails
        if let failure = setFailure {
            lock.unlock()
            throw PowerModeError.setFailed(failure)
        }
        if compliant { _readResult = .mode(mode) }
        lock.unlock()
    }

    /// Await until at least `n` set calls have been attempted. Bounded on
    /// purpose: an unbounded wait here would hang the entire test runner
    /// instead of failing the test.
    func waitForSetCount(_ n: Int, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let met: Bool
            lock.lock()
            met = setCalls.count >= n
            lock.unlock()
            if met { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        let attempted: Int
        lock.lock()
        attempted = setCalls.count
        lock.unlock()
        guard attempted >= n else {
            throw StubError.timeout(expected: n, attempted: attempted)
        }
    }
}

enum StubError: Error, CustomStringConvertible {
    case timeout(expected: Int, attempted: Int)

    var description: String {
        switch self {
        case .timeout(let expected, let attempted):
            return "stub timed out: expected \(expected) set calls, saw \(attempted)"
        }
    }
}

// MARK: - Decision function

@Suite("PowerMode decisions")
struct PowerModeDecisionTests {
    /// 88°C engage / 70°C release — the proven v1 values.
    let config = PowerModeConfig.default

    @Test("engages reduced exactly at the high threshold")
    func engageBoundary() {
        #expect(PowerModeController.requiredMode(peakTemp: 88, current: .high, config: config) == .reduced)
    }

    @Test("does not act just below the high threshold")
    func belowHigh() {
        #expect(PowerModeController.requiredMode(peakTemp: 87.9, current: .high, config: config) == nil)
    }

    @Test("releases to high exactly at the low threshold")
    func releaseBoundary() {
        #expect(PowerModeController.requiredMode(peakTemp: 70, current: .reduced, config: config) == .high)
    }

    @Test("never re-asserts a mode already in effect")
    func dedupe() {
        #expect(PowerModeController.requiredMode(peakTemp: 95, current: .reduced, config: config) == nil)
        #expect(PowerModeController.requiredMode(peakTemp: 40, current: .high, config: config) == nil)
    }

    @Test("inside the hysteresis band: no action in either state")
    func inBand() {
        #expect(PowerModeController.requiredMode(peakTemp: 80, current: .reduced, config: config) == nil)
        #expect(PowerModeController.requiredMode(peakTemp: 80, current: .high, config: config) == nil)
    }

    @Test("unknown current mode: acts only in the safe direction")
    func unknownMode() {
        #expect(PowerModeController.requiredMode(peakTemp: 90, current: nil, config: config) == .reduced)
        #expect(PowerModeController.requiredMode(peakTemp: 60, current: nil, config: config) == nil)
    }

    @Test("disabled: never acts, even in the danger zone")
    func disabled() {
        let off = PowerModeConfig(enabled: false, highTemp: 88, lowTemp: 70)
        #expect(PowerModeController.requiredMode(peakTemp: 99, current: .high, config: off) == nil)
        #expect(PowerModeController.requiredMode(peakTemp: 30, current: .reduced, config: off) == nil)
    }

    @Test("no temperature reading: never acts")
    func noTemperature() {
        #expect(PowerModeController.requiredMode(peakTemp: nil, current: .high, config: config) == nil)
    }

    @Test("custom thresholds are respected")
    func customThresholds() {
        let c = PowerModeConfig(enabled: true, highTemp: 80, lowTemp: 60)
        #expect(PowerModeController.requiredMode(peakTemp: 80, current: .high, config: c) == .reduced)
        #expect(PowerModeController.requiredMode(peakTemp: 60, current: .reduced, config: c) == .high)
        #expect(PowerModeController.requiredMode(peakTemp: 70, current: .high, config: c) == nil)
    }
}

// MARK: - Controller loop

@Suite("PowerMode controller")
struct PowerModeControllerTests {

    @Test("switches to reduced when hot, verified by read-back")
    func engage() async throws {
        let stub = StubPowerModeBackend(reading: .mode(.high))
        let controller = PowerModeController(backend: stub, minSetInterval: 0)

        controller.evaluate(peakTemp: 88)
        try await stub.waitForSetCount(1)
        try await Task.sleep(for: .milliseconds(50))

        #expect(stub.setCalls == [.reduced])
        #expect(controller.state.currentMode == .reduced)
        #expect(controller.state.warning == nil)
    }

    @Test("restores high performance once cooled (full engage/release cycle)")
    func release() async throws {
        let stub = StubPowerModeBackend(reading: .mode(.high))
        let controller = PowerModeController(backend: stub, minSetInterval: 0)

        controller.evaluate(peakTemp: 88)
        try await stub.waitForSetCount(1)
        controller.evaluate(peakTemp: 70)
        try await stub.waitForSetCount(2)
        try await Task.sleep(for: .milliseconds(50))

        #expect(stub.setCalls == [.reduced, .high])
        #expect(controller.state.currentMode == .high)
    }

    @Test("in-band temperature: no set is issued")
    func inBand() async throws {
        let stub = StubPowerModeBackend(reading: .mode(.high))
        let controller = PowerModeController(backend: stub, minSetInterval: 0)

        controller.evaluate(peakTemp: 80)
        try await Task.sleep(for: .milliseconds(50))

        #expect(stub.setCalls.isEmpty)
    }

    @Test("unknown mode + hot: still asserts reduced (safe direction)")
    func unknownButHot() async throws {
        let stub = StubPowerModeBackend(reading: .mode(.high))
        let controller = PowerModeController(backend: stub, minSetInterval: 0)

        // No refresh yet → currentMode nil. Hot must still act.
        controller.evaluate(peakTemp: 92)
        try await stub.waitForSetCount(1)

        #expect(stub.setCalls == [.reduced])
    }

    @Test("set failure: warning surfaces, retries back off (no pmset hammering)")
    func setFailure() async throws {
        let stub = StubPowerModeBackend(reading: .mode(.high))
        stub.setFailure = "sudo: a terminal is required to read the password"
        let controller = PowerModeController(backend: stub, minSetInterval: 0)

        controller.evaluate(peakTemp: 90)
        try await stub.waitForSetCount(1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.state.warning?.contains("terminal") ?? false)

        // Repeated hot ticks must NOT hammer pmset while backed off.
        controller.evaluate(peakTemp: 91)
        controller.evaluate(peakTemp: 92)
        try await Task.sleep(for: .milliseconds(50))
        #expect(stub.setCalls.count == 1)
    }

    @Test("verify mismatch (non-compliant system): surfaced, no tight loop")
    func verifyMismatch() async throws {
        let stub = StubPowerModeBackend(reading: .mode(.high), compliant: false)
        let controller = PowerModeController(backend: stub, minSetInterval: 0)

        controller.evaluate(peakTemp: 90)
        try await stub.waitForSetCount(1)
        try await Task.sleep(for: .milliseconds(50))

        // Read-back still reports high → mismatch warning, backoff armed.
        #expect(controller.state.warning?.contains("reports") ?? false)

        controller.evaluate(peakTemp: 91)
        try await Task.sleep(for: .milliseconds(50))
        #expect(stub.setCalls.count == 1)
    }

    @Test("hot machine flipped to high performance externally is re-protected")
    func externalChange() async throws {
        let stub = StubPowerModeBackend(reading: .mode(.high))
        let controller = PowerModeController(backend: stub, minSetInterval: 0)

        controller.refreshMode()
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.state.currentMode == .high)

        // Gets hot → controller drops to reduced.
        controller.evaluate(peakTemp: 90)
        try await stub.waitForSetCount(1)
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.state.currentMode == .reduced)

        // Still hot — and something external flips the system back to high.
        // (This is the v1 stale-state hole: the script would do nothing.)
        stub.readResultToReturn = .mode(.high)
        controller.refreshMode()
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.state.currentMode == .high)

        // Next hot tick must re-assert reduced.
        controller.evaluate(peakTemp: 91)
        try await stub.waitForSetCount(2)
        #expect(stub.setCalls == [.reduced, .reduced])
    }

    @Test("pmset without the powermode key: warns once, never attempts sets")
    func keyAbsent() async throws {
        let stub = StubPowerModeBackend(reading: .keyAbsent)
        let controller = PowerModeController(backend: stub, minSetInterval: 0)

        controller.refreshMode()
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.state.warning?.contains("no powermode key") ?? false)

        controller.evaluate(peakTemp: 95)
        try await Task.sleep(for: .milliseconds(50))
        #expect(stub.setCalls.isEmpty)
    }

    @Test("config update: new thresholds act on the next tick")
    func configUpdate() async throws {
        let stub = StubPowerModeBackend(reading: .mode(.high))
        let controller = PowerModeController(backend: stub, minSetInterval: 0)

        controller.refreshMode()
        try await Task.sleep(for: .milliseconds(50))

        controller.update(config: PowerModeConfig(enabled: true, highTemp: 75, lowTemp: 60))
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.state.highTemp == 75)

        controller.evaluate(peakTemp: 76)
        try await stub.waitForSetCount(1)
        #expect(stub.setCalls == [.reduced])
    }

    @Test("disabled config stops acting, keeps the last verified mode")
    func disabled() async throws {
        let stub = StubPowerModeBackend(reading: .mode(.reduced))
        let controller = PowerModeController(backend: stub, minSetInterval: 0)

        controller.refreshMode()
        try await Task.sleep(for: .milliseconds(50))

        controller.update(config: PowerModeConfig(enabled: false, highTemp: 88, lowTemp: 70))
        try await Task.sleep(for: .milliseconds(50))

        controller.evaluate(peakTemp: 95)
        try await Task.sleep(for: .milliseconds(50))
        #expect(stub.setCalls.isEmpty)
        #expect(controller.state.currentMode == .reduced)
    }
}

// MARK: - pmset output parsing

@Suite("pmset output parsing")
struct PmsetParseTests {

    @Test("effective mode from real-world pmset -g shape")
    func effectiveMode() {
        // Captured on the M4 Pro dev machine (m5dev.local).
        let output = """
        System-wide power settings:
        Currently in use:
         standby              1
         Sleep On Power Button 1
         hibernatefile        /var/vm/sleepimage
         powernap             1
         powermode            1
         womp                 1
        """
        #expect(PmsetPowerModeBackend.parseEffectiveMode(output) == .mode(.reduced))
    }

    @Test("high performance value")
    func highMode() {
        let output = "Currently in use:\n powermode            2\n womp                 1\n"
        #expect(PmsetPowerModeBackend.parseEffectiveMode(output) == .mode(.high))
    }

    @Test("a lowpowermode line never matches (exact-token rule)")
    func noSubstringMatch() {
        let output = "Currently in use:\n lowpowermode         1\n standby              1\n"
        #expect(PmsetPowerModeBackend.parseEffectiveMode(output) == .keyAbsent)
    }

    @Test("an unrecognized value is reported, not swallowed")
    func unknownValue() {
        let output = "Currently in use:\n powermode            3\n"
        #expect(PmsetPowerModeBackend.parseEffectiveMode(output) == .unknownValue(3))
    }

    @Test("empty output is keyAbsent (older OS)")
    func empty() {
        #expect(PmsetPowerModeBackend.parseEffectiveMode("") == .keyAbsent)
    }
}

// MARK: - Config

@Suite("PowerMode config")
struct PowerModeConfigTests {

    @Test("defaults: on, 88°C engage, 70°C release")
    func defaults() {
        #expect(PowerModeConfig.default == PowerModeConfig(enabled: true, highTemp: 88, lowTemp: 70))
    }

    @Test("UserDefaults round-trip")
    func roundTrip() {
        let defaults = UserDefaults(suiteName: "powermode-test")!
        defaults.removePersistentDomain(forName: "powermode-test")

        let fresh = PowerModeConfig(defaults: defaults)
        #expect(fresh == .default)

        var custom = PowerModeConfig(enabled: false, highTemp: 85, lowTemp: 65)
        custom.validate()
        custom.save(to: defaults)

        let reloaded = PowerModeConfig(defaults: defaults)
        #expect(reloaded == custom)
    }

    @Test("clamping keeps thresholds sane and the hysteresis gap intact")
    func clamping() {
        var outOfRange = PowerModeConfig(enabled: true, highTemp: 200, lowTemp: 10)
        outOfRange.validate()
        #expect(outOfRange.highTemp == 100)
        #expect(outOfRange.lowTemp == 30)

        var inverted = PowerModeConfig(enabled: true, highTemp: 88, lowTemp: 95)
        inverted.validate()
        #expect(inverted.lowTemp == 86)   // capped at high − 2
        #expect(inverted.lowTemp < inverted.highTemp)
    }
}

// MARK: - ThermalStatus peak

@Suite("ThermalStatus")
struct ThermalStatusTests {

    @Test("maxSensorTemperature is the max over ALL reported sensors")
    func maxSensor() {
        let status = ThermalStatus(
            fans: [
                ThermalStatus.FanStatus(index: 0, actualRPM: 0, targetRPM: 0, minRPM: 1200, maxRPM: 9000, mode: "auto")
            ],
            temperatures: ["TC0A": 80, "TG0P": 74.5, "Tm02": 91.2, "TAOS": 30]
        )
        #expect(status.maxSensorTemperature == 91.2)
    }

    @Test("empty temperatures → nil")
    func empty() {
        let status = ThermalStatus(fans: [], temperatures: [:])
        #expect(status.maxSensorTemperature == nil)
    }
}
