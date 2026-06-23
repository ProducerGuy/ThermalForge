//
//  FanControlTests.swift
//  ThermalForge
//
//  Unit tests for the polling optimizations: live-key probing (#3), the cheap
//  control read that touches only CPU/GPU (#4), and caching of firmware-static
//  facts — fan count + min/max RPM (#5). Backed by a fake SMC key table so the
//  tests assert exactly which keys get read, with no real hardware.
//

import Testing

@testable import ThermalForgeCore

/// In-memory SMC stand-in. Holds a key table and counts every read so tests can
/// assert that absent / display-only keys aren't re-read on the hot path.
final class FakeSMC: SMCReading {
    private struct Entry { var bytes: [UInt8]; var size: UInt32 }
    private var table: [String: Entry] = [:]
    private(set) var readCounts: [String: Int] = [:]

    func setFloat(_ key: String, _ value: Float) {
        table[key] = Entry(bytes: floatToSMCBytes(value), size: 4)
    }

    func setIoft(_ key: String, _ value: Float) {
        let raw = UInt32(value * 65536).littleEndian
        let four = withUnsafeBytes(of: raw) { Array($0) }
        table[key] = Entry(bytes: four + [0, 0, 0, 0], size: 8)
    }

    func setByte(_ key: String, _ value: UInt8) {
        table[key] = Entry(bytes: [value], size: 1)
    }

    func reads(_ key: String) -> Int { readCounts[key, default: 0] }

    // MARK: SMCReading
    func readKey(_ key: String) -> (success: Bool, bytes: [UInt8], size: UInt32) {
        readCounts[key, default: 0] += 1
        guard let e = table[key] else { return (false, [], 0) }
        return (true, e.bytes, e.size)
    }
    func writeKey(_ key: String, bytes: [UInt8]) -> Bool {
        if table[key] != nil { table[key]!.bytes = bytes }
        return true
    }
    func getKeyInfo(_ key: String) -> (size: UInt32, type: String)? {
        table[key].map { ($0.size, "flt ") }
    }
    func getKeyCount() -> UInt32 { UInt32(table.count) }
    func getKeyAtIndex(_ index: UInt32) -> String? { nil }
}

/// A single-fan machine with a representative temperature key set:
/// CPU = TCDX/Tp01/Tp09, GPU = Tg05 (flt) + TG0B (ioft), plus display-only
/// RAM/SSD/ambient sensors. Other candidate keys are deliberately absent.
private func makeFakeMachine() -> FakeSMC {
    let smc = FakeSMC()
    // Fan 0 (manual mode → lowercase template detected)
    smc.setByte("FNum", 1)
    smc.setByte("F0md", 1)
    smc.setFloat("F0Ac", 1500)
    smc.setFloat("F0Tg", 1500)
    smc.setFloat("F0Mn", 2317)
    smc.setFloat("F0Mx", 7826)
    // CPU
    smc.setFloat("TCDX", 60.0)
    smc.setFloat("Tp01", 55.0)
    smc.setFloat("Tp09", 62.5)
    // GPU — both flt and ioft paths
    smc.setFloat("Tg05", 48.0)
    smc.setIoft("TG0B", 50.0)
    // Display-only
    smc.setFloat("Tm02", 40.0)
    smc.setFloat("TH0A", 45.0)
    smc.setFloat("TA0P", 30.0)
    return smc
}

@Suite("Fan Control polling")
struct FanControlTests {

    @Test("controlTemps returns the CPU and GPU peaks")
    func controlTempsPeaks() {
        let fc = FanControl(smc: makeFakeMachine())
        let temps = fc.controlTemps()
        #expect(temps?.cpu == 62.5)   // max(TCDX 60, Tp01 55, Tp09 62.5)
        #expect(temps?.gpu == 50.0)   // max(Tg05 48, TG0B 50)
    }

    @Test("control read never touches display-only or absent sensors (#3, #4)")
    func controlReadStaysOnCpuGpu() {
        let smc = makeFakeMachine()
        let fc = FanControl(smc: smc)

        for _ in 0..<3 { _ = fc.controlTemps() }

        // Present CPU/GPU keys: probed once + read on each of the 3 calls.
        #expect(smc.reads("TCDX") == 4)
        #expect(smc.reads("TG0B") == 4)
        // Display-only keys: probed once, then never touched by the control path.
        #expect(smc.reads("Tm02") == 1)
        #expect(smc.reads("TH0A") == 1)
        #expect(smc.reads("TA0P") == 1)
        // Absent candidate: probed once, never read again.
        #expect(smc.reads("Tp02") == 1)
    }

    @Test("Fan count and min/max RPM are read once, not per call (#5)")
    func staticFanFactsCached() {
        let smc = makeFakeMachine()
        let fc = FanControl(smc: smc)

        for _ in 0..<3 { _ = try? fc.status() }
        _ = fc.primaryFanLimits()

        #expect(smc.reads("FNum") == 1)     // fan count cached after first read
        #expect(smc.reads("F0Mn") == 1)     // min RPM is firmware-static → cached
        #expect(smc.reads("F0Mx") == 1)     // max RPM cached
        #expect(smc.reads("F0Ac") == 3)     // actual RPM still read fresh each status
    }

    @Test("status reports exactly the live sensors, decoded correctly")
    func statusReportsLiveSensors() throws {
        let fc = FanControl(smc: makeFakeMachine())
        let status = try fc.status()
        let temps = status.temperatures

        #expect(temps["TCDX"] == 60.0)
        #expect(temps["Tp09"] == 62.5)
        #expect(temps["TG0B"] == 50.0)   // ioft 16.16 decode
        #expect(temps["Tm02"] == 40.0)
        // Absent candidates never appear.
        #expect(temps["Tp02"] == nil)
        #expect(temps["TG0H"] == nil)
        #expect(status.fans.count == 1)
        #expect(status.fans.first?.maxRPM == 7826)
    }

    @Test("controlTemps and status agree on the CPU/GPU peaks")
    func controlAndStatusAgree() throws {
        let fc = FanControl(smc: makeFakeMachine())
        let control = fc.controlTemps()
        let status = try fc.status()

        let cpu = status.temperatures.filter { k, _ in k.hasPrefix("TC") || k.hasPrefix("Tp") }.values.max()
        let gpu = status.temperatures.filter { k, _ in k.hasPrefix("TG") || k.hasPrefix("Tg") }.values.max()
        #expect(control?.cpu == cpu)
        #expect(control?.gpu == gpu)
    }

    @Test("controlTemps returns nil when no CPU/GPU sensor is present")
    func controlTempsNilWithoutSensors() {
        let smc = FakeSMC()
        smc.setByte("FNum", 1)
        smc.setFloat("F0Mx", 7826)   // a fan key, but no temperature keys
        let fc = FanControl(smc: smc)
        #expect(fc.controlTemps() == nil)
    }
}
