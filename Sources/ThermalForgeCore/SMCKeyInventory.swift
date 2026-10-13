import Foundation

/// A connection-local, firmware-enumerated inventory. Missing keys are skipped
/// only after every index was read successfully; an incomplete enumeration is
/// fail-open. No per-read I/O failure is ever recorded as an absent sensor.
struct SMCKeyInventory {
    private var keys: Set<String>?
    var isComplete: Bool { keys != nil }

    func mayContain(_ key: String) -> Bool {
        // #KEY bootstraps the inventory and must remain readable.
        key == "#KEY" || (keys?.contains(key) ?? true)
    }

    @discardableResult
    mutating func rebuild(count: UInt32, keyAtIndex: (UInt32) -> String?) -> Bool {
        keys = nil
        guard count > 0, count < 100_000 else { return false }
        var discovered = Set<String>()
        for index in 0..<count {
            guard let key = keyAtIndex(index), key.utf8.count == 4,
                  key.utf8.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }),
                  discovered.insert(key).inserted else { return false }
        }
        keys = discovered
        return true
    }
}
