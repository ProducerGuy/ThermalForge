import Testing
@testable import ThermalForgeCore

@Suite("Fan release — no hardware writes")
struct FanReleaseTests {
    @Test("A failed mode write still attempts the other fan and Ftst")
    func partialFailure() {
        var keys: [String] = []
        #expect(throws: (any Error).self) {
            try FanRelease.release(indices: [0, 1], hasFtst: true,
                                   modeKey: { "F\($0)Md" }, read: { _ in nil }) { key, _ in
                keys.append(key)
                return key != "F0Md"
            }
        }
        #expect(keys == ["F0Md", "F0Tg", "F1Md", "F1Tg", "Ftst"])
    }

    @Test("A rejected Ftst reset is reported by key")
    func forceTestFailure() {
        do {
            try FanRelease.release(indices: [0, 1], hasFtst: true,
                                   modeKey: { "F\($0)Md" }, read: { _ in nil }) { key, _ in key != "Ftst" }
            Issue.record("Expected the Ftst write to fail")
        } catch ThermalForgeError.writeFailed(let key) {
            #expect(key == "Ftst")
        } catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test("Advisory target failures do not invalidate successful mode recovery")
    func advisoryFailure() throws {
        var keys: [String] = []
        try FanRelease.release(indices: [0, 1], hasFtst: false,
                               modeKey: { "F\($0)md" }, read: { _ in nil }) { key, _ in
            keys.append(key)
            return !key.hasSuffix("Tg")
        }
        #expect(keys == ["F0md", "F0Tg", "F1md", "F1Tg"])
    }

    @Test("Rejected redundant mode writes are accepted only after automatic readback", arguments: [UInt8(0), 3])
    func alreadyAutomatic(mode: UInt8) throws {
        try FanRelease.release(indices: [0, 1], hasFtst: true,
                               modeKey: { "F\($0)Md" },
                               read: { $0 == "Ftst" ? 0 : mode },
                               write: { _, _ in false })
    }

    @Test("Manual or unknown readback cannot hide a rejected release", arguments: [UInt8(1), 2, 255])
    func stillNotAutomatic(mode: UInt8) {
        #expect(throws: (any Error).self) {
            try FanRelease.release(indices: [0, 1], hasFtst: true,
                                   modeKey: { "F\($0)Md" },
                                   read: { $0 == "Ftst" ? 0 : mode },
                                   write: { _, _ in false })
        }
    }

    @Test("Readback follows Ftst recovery and still attempts every fan")
    func readAfterUnlockReset() throws {
        var reset = false
        var keys: [String] = []
        try FanRelease.release(indices: [0, 1], hasFtst: true,
                               modeKey: { "F\($0)Md" },
                               read: { _ in reset ? 3 : 1 }) { key, _ in
            keys.append(key)
            if key == "Ftst" { reset = true; return true }
            return false
        }
        #expect(keys == ["F0Md", "F0Tg", "F1Md", "F1Tg", "Ftst"])
    }

    @Test("A diagnostic flag still set after rejection remains an error")
    func forceTestStillEnabled() {
        #expect(throws: (any Error).self) {
            try FanRelease.release(indices: [0, 1], hasFtst: true,
                                   modeKey: { "F\($0)Md" }, read: { _ in 1 },
                                   write: { key, _ in key != "Ftst" })
        }
    }
}
