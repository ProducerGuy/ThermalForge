//
//  FanCommandPumpTests.swift
//  ThermalForge
//
//  Coalescing correctness for FanCommandPump: consecutive setRPM collapse
//  latest-wins, while resetAuto/setMax/setFan are never dropped or reordered.
//  The resetAuto case is a fan-safety property — dropping it strands fans in manual.
//

import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("FanCommandPump coalescing")
struct FanCommandPumpTests {

    /// Records executed commands and blocks the FIRST one, so a test can submit a
    /// burst that piles into the pump's pending buffer and then observe exactly which
    /// commands survive and in what order.
    final class Harness: @unchecked Sendable {
        private let lock = NSLock()
        private var _recorded: [FanCommand] = []
        let firstStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        private var didBlock = false

        @discardableResult
        func execute(_ c: FanCommand) -> Bool {
            lock.lock(); let isFirst = !didBlock; if isFirst { didBlock = true }; lock.unlock()
            if isFirst { firstStarted.signal(); releaseFirst.wait() }
            lock.lock(); _recorded.append(c); lock.unlock()
            return true
        }

        var recorded: [FanCommand] { lock.lock(); defer { lock.unlock() }; return _recorded }
    }

    /// Poll until `recorded` reaches `count` or the timeout elapses.
    private func wait(_ h: Harness, forCount count: Int, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if h.recorded.count >= count { return true }
            usleep(2_000)
        }
        return h.recorded.count >= count
    }

    /// Submit `first` (which the harness blocks in-flight), wait until it's blocked,
    /// then submit `burst` into the pending buffer, release, and return the executed
    /// sequence once `expected` commands have run.
    private func run(first: FanCommand, burst: [FanCommand], expected: Int) -> [FanCommand] {
        let h = Harness()
        let pump = FanCommandPump(queue: DispatchQueue(label: "test.pump")) { cmd in h.execute(cmd) }
        pump.submit(first)
        h.firstStarted.wait()               // `first` is now in-flight and blocking the queue
        for c in burst { pump.submit(c) }    // pile into pending; coalescing happens here
        h.releaseFirst.signal()
        _ = wait(h, forCount: expected)
        return h.recorded
    }

    @Test("consecutive setRPM collapse latest-wins; queue depth stays bounded")
    func consecutiveSetRPMCollapse() {
        let out = run(first: .setRPM(1000),
                      burst: [.setRPM(2000), .setRPM(3000), .setRPM(4000)],
                      expected: 2)
        // 2000 and 3000 are superseded; only the newest survives behind the in-flight one.
        #expect(out == [.setRPM(1000), .setRPM(4000)])
    }

    @Test("resetAuto is never dropped and never reordered behind a later setRPM")
    func resetAutoPreserved() {
        let out = run(first: .setRPM(1000),
                      burst: [.setRPM(2000), .resetAuto, .setRPM(3000)],
                      expected: 4)
        // resetAuto stays in place; the setRPM(2000) before it is NOT coalesced away
        // (the mode change breaks the consecutive-setRPM run).
        #expect(out == [.setRPM(1000), .setRPM(2000), .resetAuto, .setRPM(3000)])
    }

    @Test("setMax and setFan are never collapsed away")
    func modeChangesPreserved() {
        let out = run(first: .setRPM(1000),
                      burst: [.setMax, .setFan(index: 0, rpm: 2000), .setRPM(3000)],
                      expected: 4)
        #expect(out == [.setRPM(1000), .setMax, .setFan(index: 0, rpm: 2000), .setRPM(3000)])
    }

    @Test("setRPM separated by a mode change do NOT coalesce across it")
    func noCoalesceAcrossModeChange() {
        let out = run(first: .setRPM(1000),
                      burst: [.setRPM(2000), .setMax, .setRPM(3000)],
                      expected: 4)
        // 2000 and 3000 are on opposite sides of setMax, so neither is collapsed.
        #expect(out == [.setRPM(1000), .setRPM(2000), .setMax, .setRPM(3000)])
    }

    /// Box for capturing a completion result across the @Sendable boundary.
    final class Box: @unchecked Sendable { var value: Bool? }

    @Test("onComplete reports the executor's success result (drives Default's UI)")
    func completionReportsResult() {
        for expected in [true, false] {
            let box = Box()
            let done = DispatchSemaphore(value: 0)
            let pump = FanCommandPump(queue: DispatchQueue(label: "test.pump")) { _ in expected }
            pump.submit(.resetAuto) { ok in box.value = ok; done.signal() }
            _ = done.wait(timeout: .now() + 2)
            #expect(box.value == expected)
        }
    }
}
