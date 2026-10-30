//
//  SMCReadCacheTests.swift
//  ThermalForge
//
//  Hardware-gated: skipped where there is no AppleSMC (e.g. CI VMs).
//

import Darwin
import Testing

@testable import ThermalForgeCore

private func machSyscalls() -> Int32 {
    var info = task_events_info()
    var count = mach_msg_type_number_t(MemoryLayout<task_events_info>.size / MemoryLayout<natural_t>.size)
    _ = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_EVENTS_INFO), $0, &count)
        }
    }
    return info.syscalls_mach
}

@Suite("SMC read cache")
struct SMCReadCacheTests {

    @Test("Cached reads return the same keys and values, with fewer Mach calls",
          .enabled(if: SMCConnection() != nil, "no AppleSMC on this machine"))
    func cachedStatusMatchesAndIsCheaper() throws {
        let fc = try FanControl()
        let first = try fc.status()   // cold: probes every key in thermalKeys
        let before = machSyscalls()
        let n: Int32 = 20
        var last = first
        for _ in 0..<n { last = try fc.status() }
        let perCall = (machSyscalls() - before) / n

        print("thermalKeys: \(FanControl.thermalKeys.count), present: \(first.temperatures.count), "
              + "fans: \(first.fans.count), Mach syscalls per warm status(): \(perCall)")

        // Same sensors found warm as cold (the absent-key cache must not hide real keys).
        #expect(Set(last.temperatures.keys) == Set(first.temperatures.keys))
        #expect(last.fans.count == first.fans.count)
        // One IOKit call per present temp key, plus fan reads. Generous bound; the
        // uncached path costs ~2 calls for each of the 50 thermalKeys alone.
        #expect(perCall < Int32(FanControl.thermalKeys.count))
    }

    @Test("An absent key keeps failing, a present key keeps reading",
          .enabled(if: SMCConnection() != nil, "no AppleSMC on this machine"))
    func absentAndPresentKeysAreStable() throws {
        let smc = try #require(SMCConnection())
        for _ in 0..<3 {
            #expect(smc.readKey("zzzz").success == false)
            let k = smc.readKey("#KEY")
            #expect(k.success && k.size == 4)
        }
        // A cached read decodes the same bytes as an uncached read on a new connection.
        let fresh = try #require(SMCConnection())
        #expect(smc.readKey("#KEY").bytes == fresh.readKey("#KEY").bytes)
    }
}
