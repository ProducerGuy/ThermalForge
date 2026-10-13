import Testing
@testable import ThermalForgeCore

@Suite("SMC key inventory")
struct SMCKeyInventoryTests {
    @Test("A complete inventory skips absent keys without probing them again")
    func missingKeys() {
        var inventory = SMCKeyInventory()
        #expect(inventory.mayContain("Tp01"))
        #expect(inventory.rebuild(count: 2) { ["TCHP", "TG0H"][Int($0)] })
        #expect(inventory.isComplete)
        #expect(inventory.mayContain("TCHP"))
        #expect(inventory.mayContain("TG0H"))
        #expect(!inventory.mayContain("Tp01"))
        #expect(inventory.mayContain("#KEY"))
    }
    @Test("Each connection uses its own hardware inventory")
    func differentMachines() {
        var first = SMCKeyInventory()
        var second = SMCKeyInventory()
        first.rebuild(count: 1) { _ in "TCHP" }
        second.rebuild(count: 1) { _ in "Tp01" }
        #expect(!first.mayContain("Tp01"))
        #expect(second.mayContain("Tp01"))
        #expect(!second.mayContain("TCHP"))
    }
    @Test("A failed or partial enumeration excludes no sensors and can be retried")
    func transientFailures() {
        var inventory = SMCKeyInventory()
        #expect(!inventory.rebuild(count: 2) { $0 == 0 ? "TCHP" : nil })
        #expect(!inventory.isComplete)
        #expect(inventory.mayContain("TG0H"))
        #expect(inventory.rebuild(count: 2) { ["TCHP", "TG0H"][Int($0)] })
        #expect(inventory.mayContain("TG0H"))
    }
    @Test("Invalid counts, malformed keys and duplicate indices fail open")
    func corruptInventory() {
        var inventory = SMCKeyInventory()
        for count: UInt32 in [0, 100_000] {
            #expect(!inventory.rebuild(count: count) { _ in "TCHP" })
            #expect(inventory.mayContain("Tp01"))
        }
        for invalid in ["TC", "TCHPX", "\0\0\0\0", "éé"] {
            #expect(!inventory.rebuild(count: 1) { _ in invalid })
            #expect(inventory.mayContain("Tp01"))
        }
        #expect(!inventory.rebuild(count: 2) { _ in "TCHP" })
        #expect(inventory.mayContain("Tp01"))
    }
    @Test("Wake/reconnect invalidation removes exclusions and discovers new keys")
    func invalidation() {
        var inventory = SMCKeyInventory()
        inventory.rebuild(count: 1) { _ in "TCHP" }
        #expect(!inventory.mayContain("Tp01"))
        inventory = SMCKeyInventory()
        #expect(inventory.mayContain("Tp01"))
        inventory.rebuild(count: 1) { _ in "Tp01" }
        #expect(inventory.mayContain("Tp01"))
        #expect(!inventory.mayContain("TCHP"))
    }
}
