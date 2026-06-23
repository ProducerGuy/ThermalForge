//
//  CommandCoalescerTests.swift
//  ThermalForge
//
//  Unit tests for the fan-command coalescer — the mechanism that stops a
//  high-frequency ramp from piling up daemon round-trips (the profile-switch
//  freeze). Verifies: work runs off the caller's thread, a burst collapses to
//  its most recent command, and spaced-out commands are each delivered.
//

import Dispatch
import Foundation
import Testing

@testable import ThermalForgeCore

@Suite("Command Coalescer")
struct CommandCoalescerTests {

    @Test("submit never runs the handler on the caller's thread")
    func submitIsAsynchronous() {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        let coalescer = CommandCoalescer<Int>(label: "test.async") { _ in
            entered.signal()
            release.wait()
        }

        coalescer.submit(1)
        // If submit ran the handler inline, we'd be blocked in release.wait()
        // right now and could never observe `entered`. Reaching here proves the
        // handler is running on the coalescer's own queue.
        #expect(entered.wait(timeout: .now() + 2) == .success)
        release.signal()
    }

    @Test("A burst collapses to its most recent command")
    func burstCoalesces() {
        let handledLock = NSLock()
        var handled: [Int] = []

        let firstStarted = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let sawLast = DispatchSemaphore(value: 0)

        let coalescer = CommandCoalescer<Int>(label: "test.burst") { cmd in
            handledLock.lock()
            handled.append(cmd)
            handledLock.unlock()

            if cmd == 1 {
                firstStarted.signal()   // handler(1) is now running...
                release.wait()          // ...and parked until the burst is queued
            }
            if cmd == 99 { sawLast.signal() }
        }

        coalescer.submit(1)
        #expect(firstStarted.wait(timeout: .now() + 2) == .success)

        // Queued while the drainer is busy with 1: 2 and 3 get overwritten by 99.
        coalescer.submit(2)
        coalescer.submit(3)
        coalescer.submit(99)

        release.signal()
        #expect(sawLast.wait(timeout: .now() + 2) == .success)

        handledLock.lock()
        let result = handled
        handledLock.unlock()
        #expect(result == [1, 99], "Expected the burst to collapse to [1, 99], got \(result)")
    }

    @Test("Commands submitted with the drainer idle are each delivered")
    func sequentialDeliveryWhenIdle() {
        let handledLock = NSLock()
        var handled: [Int] = []
        let done = DispatchSemaphore(value: 0)

        let coalescer = CommandCoalescer<Int>(label: "test.sequential") { cmd in
            handledLock.lock()
            handled.append(cmd)
            handledLock.unlock()
            if cmd == 3 { done.signal() }
        }

        // Each submit waits for the previous to be observed, so the drainer is
        // idle between them — nothing should be coalesced away.
        for value in 1...3 {
            coalescer.submit(value)
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline {
                handledLock.lock()
                let seen = handled.contains(value)
                handledLock.unlock()
                if seen { break }
                Thread.sleep(forTimeInterval: 0.005)
            }
        }

        #expect(done.wait(timeout: .now() + 2) == .success)
        handledLock.lock()
        let result = handled
        handledLock.unlock()
        #expect(result == [1, 2, 3])
    }
}
