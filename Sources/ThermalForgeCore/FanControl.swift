//
//  FanControl.swift
//  ThermalForge
//
//  Core fan control operations: unlock, set speed, reset, status, discover.
//

import Foundation

// MARK: - Types

public enum ThermalForgeError: Error, CustomStringConvertible {
    case smcConnectionFailed
    case unlockFailed(String)
    case readFailed(String)
    case writeFailed(String)
    case rpmOutOfRange(requested: Float, min: Float, max: Float)

    public var description: String {
        switch self {
        case .smcConnectionFailed:
            return "Failed to connect to AppleSMC. Is this a Mac with SMC?"
        case .unlockFailed(let detail):
            return "Fan unlock failed: \(detail)"
        case .readFailed(let key):
            return "Failed to read SMC key: \(key)"
        case .writeFailed(let key):
            return "Failed to write SMC key: \(key). Run with sudo."
        case .rpmOutOfRange(let req, let min, let max):
            return "RPM \(Int(req)) is out of range [\(Int(min))–\(Int(max))]"
        }
    }
}

public struct FanInfo {
    public let index: Int
    public let actualRPM: Float
    public let targetRPM: Float
    public let minRPM: Float
    public let maxRPM: Float
    public let mode: String
}

public struct ThermalStatus: Encodable {
    public let fans: [FanStatus]
    public let temperatures: [String: Float]

    public struct FanStatus: Encodable {
        public let index: Int
        public let actualRPM: Int
        public let targetRPM: Int
        public let minRPM: Int
        public let maxRPM: Int
        public let mode: String
    }
}

extension ThermalStatus {
    /// Peak of the CPU (`TC`/`Tp`) and GPU (`TG`/`Tg`) sensors — the temperature the
    /// thermal safety floor watches. Single source of truth so the client
    /// `ThermalMonitor` and the daemon's floor read the identical value; mirroring
    /// can't drift because it's the same code.
    public var safetyPeakTemp: Float {
        func peak(_ prefixes: [String]) -> Float {
            temperatures.filter { key, _ in prefixes.contains { key.hasPrefix($0) } }
                .values.max() ?? 0
        }
        return max(peak(["TC", "Tp"]), peak(["TG", "Tg"]))
    }
}

public struct DiscoveredKey {
    public let key: String
    public let size: UInt32
    public let type: String
    public let bytes: [UInt8]
}

// MARK: - Fan Control

public final class FanControl {
    private let smc: SMCConnection
    /// Which mode key works on this hardware (detected at init)
    private let modeKeyTemplate: String
    /// Whether Ftst unlock is available (M1-M4) or not (M5+)
    private let hasFtst: Bool

    public init() throws {
        guard let connection = SMCConnection() else {
            throw ThermalForgeError.smcConnectionFailed
        }
        self.smc = connection

        // Detect hardware: which mode key exists?
        // M5 Max uses F%dmd (lowercase), M1-M4 use F%dMd (uppercase)
        let lowerResult = smc.readKey(SMCFanKey.key(SMCFanKey.modeLower, fan: 0))
        if lowerResult.success {
            self.modeKeyTemplate = SMCFanKey.modeLower
        } else {
            self.modeKeyTemplate = SMCFanKey.modeUpper
        }

        // Check if Ftst exists (M1-M4 unlock mechanism)
        if let info = smc.getKeyInfo(SMCFanKey.forceTest), info.size > 0 {
            self.hasFtst = true
        } else {
            self.hasFtst = false
        }
    }

    // MARK: - Fan Count

    public func fanCount() throws -> Int {
        let result = smc.readKey(SMCFanKey.count)
        guard result.success, !result.bytes.isEmpty else {
            throw ThermalForgeError.readFailed(SMCFanKey.count)
        }
        return Int(result.bytes[0])
    }

    // MARK: - Read Fan Info

    public func fanInfo(_ index: Int) throws -> FanInfo {
        let actual = readFanFloat(index, template: SMCFanKey.actual)
        let target = readFanFloat(index, template: SMCFanKey.target)
        let minimum = readFanFloat(index, template: SMCFanKey.minimum)
        let maximum = readFanFloat(index, template: SMCFanKey.maximum)

        let modeKey = SMCFanKey.key(modeKeyTemplate, fan: index)
        let modeResult = smc.readKey(modeKey)
        let modeValue = modeResult.success && !modeResult.bytes.isEmpty ? modeResult.bytes[0] : 0
        let mode: String
        switch modeValue {
        case 0: mode = "auto"
        case 1: mode = "manual"
        case 3: mode = "system"
        default: mode = "unknown(\(modeValue))"
        }

        return FanInfo(
            index: index,
            actualRPM: actual,
            targetRPM: target,
            minRPM: minimum,
            maxRPM: maximum,
            mode: mode
        )
    }

    // MARK: - Unlock

    /// Unlock fans for manual control.
    /// On M1-M4: writes Ftst=1, then polls until mode write succeeds.
    /// On M5+: Ftst doesn't exist, attempts direct mode write.
    private func unlockFans(count: Int) throws {
        if hasFtst {
            // M1-M4 path: Ftst unlock suppresses thermalmonitord
            guard smc.writeKey(SMCFanKey.forceTest, bytes: [1]) else {
                throw ThermalForgeError.unlockFailed(
                    "Failed to write Ftst=1. Run with sudo."
                )
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        // Set each fan to manual mode
        for i in 0..<count {
            let modeKey = SMCFanKey.key(modeKeyTemplate, fan: i)
            let deadline = Date().addingTimeInterval(10.0)
            var success = false

            while Date() < deadline {
                if smc.writeKey(modeKey, bytes: [1]) {
                    success = true
                    break
                }
                Thread.sleep(forTimeInterval: 0.1)
            }

            if !success {
                throw ThermalForgeError.unlockFailed(
                    "Timed out setting fan \(i) to manual mode. Run with sudo."
                )
            }
        }
    }

    /// Unlock a single fan for manual control
    private func unlockSingleFan(_ index: Int) throws {
        if hasFtst {
            guard smc.writeKey(SMCFanKey.forceTest, bytes: [1]) else {
                throw ThermalForgeError.unlockFailed(
                    "Failed to write Ftst=1. Run with sudo."
                )
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        let modeKey = SMCFanKey.key(modeKeyTemplate, fan: index)
        let deadline = Date().addingTimeInterval(10.0)

        while Date() < deadline {
            if smc.writeKey(modeKey, bytes: [1]) {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        throw ThermalForgeError.unlockFailed(
            "Timed out setting fan \(index) to manual mode. Run with sudo."
        )
    }

    // MARK: - Set Speed

    /// Set all fans to maximum RPM
    public func setMax() throws {
        let count = try fanCount()
        try unlockFans(count: count)

        for i in 0..<count {
            let info = try fanInfo(i)
            let maxRPM = info.maxRPM > 0 ? info.maxRPM : 7826

            let targetKey = SMCFanKey.key(SMCFanKey.target, fan: i)
            guard smc.writeKey(targetKey, bytes: floatToSMCBytes(maxRPM)) else {
                throw ThermalForgeError.writeFailed(targetKey)
            }
            log("Set fan \(i) to max (\(Int(maxRPM)) RPM)")
        }
    }

    /// Set a single fan to a specific RPM
    public func setSpeed(fan index: Int, rpm: Float) throws {
        let info = try fanInfo(index)

        // Safety: never below minimum
        if info.minRPM > 0 && rpm < info.minRPM {
            throw ThermalForgeError.rpmOutOfRange(
                requested: rpm, min: info.minRPM, max: info.maxRPM
            )
        }

        // Safety: never above maximum
        if info.maxRPM > 0 && rpm > info.maxRPM {
            throw ThermalForgeError.rpmOutOfRange(
                requested: rpm, min: info.minRPM, max: info.maxRPM
            )
        }

        if info.mode != "manual" {
            try unlockSingleFan(index)
        }

        let targetKey = SMCFanKey.key(SMCFanKey.target, fan: index)
        guard smc.writeKey(targetKey, bytes: floatToSMCBytes(rpm)) else {
            throw ThermalForgeError.writeFailed(targetKey)
        }
        log("Set fan \(index) to \(Int(rpm)) RPM")
    }

    /// Set all fans to a specific RPM
    public func setAllFans(rpm: Float) throws {
        let count = try fanCount()

        // Validate against first fan's limits
        let info = try fanInfo(0)
        if info.minRPM > 0 && rpm < info.minRPM {
            throw ThermalForgeError.rpmOutOfRange(
                requested: rpm, min: info.minRPM, max: info.maxRPM
            )
        }
        if info.maxRPM > 0 && rpm > info.maxRPM {
            throw ThermalForgeError.rpmOutOfRange(
                requested: rpm, min: info.minRPM, max: info.maxRPM
            )
        }

        try unlockFans(count: count)

        for i in 0..<count {
            let targetKey = SMCFanKey.key(SMCFanKey.target, fan: i)
            guard smc.writeKey(targetKey, bytes: floatToSMCBytes(rpm)) else {
                throw ThermalForgeError.writeFailed(targetKey)
            }
            log("Set fan \(i) to \(Int(rpm)) RPM")
        }
    }

    // MARK: - Reset

    /// Reset all fans to Apple defaults (auto mode, thermalmonitord resumes)
    public func resetAuto() throws {
        let count = try fanCount()

        for i in 0..<count {
            let modeKey = SMCFanKey.key(modeKeyTemplate, fan: i)
            _ = smc.writeKey(modeKey, bytes: [0])

            let targetKey = SMCFanKey.key(SMCFanKey.target, fan: i)
            _ = smc.writeKey(targetKey, bytes: floatToSMCBytes(0))
        }

        // Reset Ftst if it exists — thermalmonitord reclaims control
        if hasFtst {
            _ = smc.writeKey(SMCFanKey.forceTest, bytes: [0])
        }
        log("Reset to Apple defaults")
    }

    // MARK: - Thermal Sensor Keys

    /// All thermal sensor keys probed for `status()`. Keys absent on a given machine
    /// return nil from `readTemp` and are skipped. Single source of truth so the
    /// daemon's safety floor reads exactly the CPU/GPU subset `status()` would.
    public static let thermalKeys: [String] = [
        // CPU — aggregate (M5 Max verified)
        "TCDX", "TCHP", "TCMb",
        // CPU — per-core (Tp prefix, present across M1-M5 with varying mappings)
        "Tp01", "Tp02", "Tp03", "Tp04", "Tp05", "Tp06", "Tp07", "Tp08",
        "Tp09", "Tp0A", "Tp0B", "Tp0C", "Tp0D", "Tp0F", "Tp0G", "Tp0H",
        "Tp0J", "Tp0L", "Tp0P", "Tp0S", "Tp0T", "Tp0W", "Tp0X", "Tp0b",
        // GPU (flt — M1-M4, and ioft 8-byte — M5 Max)
        "Tg05", "Tg0D", "Tg0L", "Tg0T", "Tg0f", "Tg0j",
        "TG0B", "TG0H", "TG0V",
        // Memory
        "Tm02", "Tm06", "Tm08", "Tm09", "TRDX", "TMVR",
        // Power delivery
        "TPDX",
        // SSD
        "TH0x", "TH0A", "TH0B",
        // Ambient
        "TAOL", "TA0P",
        // Proximity
        "TS0P",
        // Battery
        "TB0T",
    ]

    /// The CPU (TC/Tp) and GPU (TG/Tg) subset the thermal safety floor watches —
    /// derived from `thermalKeys` so it can't drift from what `status()` reports.
    public static let safetyTempKeys: [String] =
        thermalKeys.filter { key in ["TC", "Tp", "TG", "Tg"].contains { key.hasPrefix($0) } }

    /// Read one temperature key, decoding by returned size (flt 4-byte or ioft 8-byte).
    /// nil if absent, wrong size, or out of the sane 0–150°C range. Does NOT lock — the
    /// caller serializes SMC access (the daemon takes smcLock per key so a full sweep
    /// never blocks a client write for more than a single read).
    public func readTemp(_ key: String) -> Float? {
        let result = smc.readKey(key)
        guard result.success else { return nil }
        let temp: Float
        if result.size == 4 {
            temp = smcBytesToFloat(result.bytes, size: result.size)
        } else if result.size == 8 {
            temp = ioftBytesToFloat(result.bytes)
        } else {
            return nil
        }
        guard temp > 0, temp < 150 else { return nil }
        return (temp * 10).rounded() / 10
    }

    // MARK: - Status

    /// Read current fan speeds and temperatures
    public func status() throws -> ThermalStatus {
        let count = try fanCount()
        var fans: [ThermalStatus.FanStatus] = []

        for i in 0..<count {
            let info = try fanInfo(i)
            fans.append(ThermalStatus.FanStatus(
                index: i,
                actualRPM: Int(info.actualRPM),
                targetRPM: Int(info.targetRPM),
                minRPM: Int(info.minRPM),
                maxRPM: Int(info.maxRPM),
                mode: info.mode
            ))
        }

        // Probe temperature keys across all known Apple Silicon generations.
        // Keys that don't exist on a given machine are skipped automatically.
        // Labels use the raw SMC key name — no assumptions about what a key
        // means on hardware we haven't verified.
        // Probe every known thermal key (flt/ioft decoded by size in readTemp). Keys
        // that don't exist on this machine return nil and are skipped.
        var temps: [String: Float] = [:]
        for key in Self.thermalKeys {
            if let t = readTemp(key) { temps[key] = t }
        }

        return ThermalStatus(fans: fans, temperatures: temps)
    }

    // MARK: - Discover

    /// Enumerate SMC keys. Optional prefix filter skips reads for non-matching keys.
    public func discover(prefix: String? = nil) -> [DiscoveredKey] {
        let count = smc.getKeyCount()
        var keys: [DiscoveredKey] = []

        for i: UInt32 in 0..<count {
            guard let keyName = smc.getKeyAtIndex(i) else { continue }

            // Skip non-matching keys early
            if let prefix = prefix, !keyName.hasPrefix(prefix) { continue }

            let info = smc.getKeyInfo(keyName)
            let result = smc.readKey(keyName)

            keys.append(DiscoveredKey(
                key: keyName,
                size: info?.size ?? 0,
                type: info?.type ?? "????",
                bytes: result.success ? result.bytes : []
            ))
        }

        return keys
    }

    // MARK: - Hardware Info

    /// Returns detected hardware capabilities
    public var hardwareInfo: String {
        let ftst = hasFtst ? "yes (M1-M4 path)" : "no (M5+ direct mode)"
        let modeKey = modeKeyTemplate == SMCFanKey.modeLower ? "F%dmd (lowercase)" : "F%dMd (uppercase)"
        return "Ftst unlock: \(ftst), Mode key: \(modeKey)"
    }

    // MARK: - Private Helpers

    private func readFanFloat(_ fan: Int, template: String) -> Float {
        let key = SMCFanKey.key(template, fan: fan)
        let result = smc.readKey(key)
        guard result.success else { return 0 }
        return smcBytesToFloat(result.bytes, size: result.size)
    }

    private func log(_ message: String) {
        TFLogger.shared.fan(message)
    }
}
