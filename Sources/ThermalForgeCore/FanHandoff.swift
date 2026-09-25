import Foundation

/// Manual-mode acquisition, separated from IOKit so slow firmware can be tested
/// without changing real fan speeds. Re-read modes on every call (including wake).
enum FanHandoff {
    // A fully stopped M4 can reject mode writes for more than ten seconds.
    // Share one 20s acquisition budget across both fans, rather than failing
    // fan 0 at 10s despite the original two-fan path allowing ~20s overall.
    static let acquisitionSeconds: TimeInterval = 20

    static func acquire(
        indices: [Int], hasFtst: Bool, modeKey: (Int) -> String,
        readMode: (Int) -> UInt8?, write: (String, [UInt8]) -> Bool,
        sleep: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) throws {
        let pending = indices.filter { readMode($0) != 1 }
        guard !pending.isEmpty else { return }
        let deadline = now() + acquisitionSeconds
        if hasFtst {
            guard write(SMCFanKey.forceTest, [1]) else {
                throw ThermalForgeError.unlockFailed("Failed to write Ftst=1. Run with sudo.")
            }
            sleep(0.5)
        }
        for index in pending {
            var succeeded = false
            while now() < deadline {
                if write(modeKey(index), [1]) {
                    succeeded = true
                    break
                }
                sleep(0.1)
            }
            guard succeeded else {
                throw ThermalForgeError.unlockFailed(
                    "Timed out setting fan \(index) to manual mode. Run with sudo."
                )
            }
        }
    }
}

/// Hardware writes may need the shared 20s firmware-handoff budget on this Mac.
/// Keep liveness/version reads fast; never extend their timeout to hide a stall.
enum DaemonRequestPolicy {
    static func timeout(for verb: DaemonRequest.Verb) -> TimeInterval {
        switch verb {
        case .max, .set, .setfan, .auto: return 30
        case .status, .state, .heartbeat, .version: return 2
        }
    }

    static func needsSMCLock(_ verb: DaemonRequest.Verb) -> Bool {
        switch verb {
        case .state, .heartbeat, .version: return false
        default: return true
        }
    }

    static func perform<T>(_ verb: DaemonRequest.Verb, lock: NSLock, _ body: () -> T) -> T {
        guard needsSMCLock(verb) else { return body() }
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
