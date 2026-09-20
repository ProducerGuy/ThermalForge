import Foundation

/// Automatic-mode recovery, separated from IOKit for failure-path tests.
enum FanRelease {
    /// Attempt every fan even if one mode write fails. Target RPM is advisory
    /// once automatic mode is restored. A rejected required write succeeds only
    /// if a fresh read after the full release confirms the desired state.
    static func release(
        indices: [Int], hasFtst: Bool, modeKey: (Int) -> String,
        read: (String) -> UInt8?,
        write: (String, [UInt8]) -> Bool
    ) throws {
        var failedModeKeys: [String] = []
        for index in indices {
            let key = modeKey(index)
            if !write(key, [0]) { failedModeKeys.append(key) }
            _ = write(SMCFanKey.key(SMCFanKey.target, fan: index), floatToSMCBytes(0))
        }
        let failedFtst = hasFtst && !write(SMCFanKey.forceTest, [0])
        // Stopped M4 fans can reject F*Md=0 while already in system mode (3).
        // Read after Ftst clears: that write can itself hand control back.
        for key in failedModeKeys {
            guard let mode = read(key), mode == 0 || mode == 3 else {
                throw ThermalForgeError.writeFailed(key)
            }
        }
        if failedFtst, read(SMCFanKey.forceTest) != 0 {
            throw ThermalForgeError.writeFailed(SMCFanKey.forceTest)
        }
    }
}
