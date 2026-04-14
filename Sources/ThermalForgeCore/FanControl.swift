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
            guard writeFanFloat(targetKey, value: maxRPM) else {
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
        guard writeFanFloat(targetKey, value: rpm) else {
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
            guard writeFanFloat(targetKey, value: rpm) else {
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
            _ = writeFanFloat(targetKey, value: 0)
        }

        // Reset Ftst if it exists — thermalmonitord reclaims control
        if hasFtst {
            _ = smc.writeKey(SMCFanKey.forceTest, bytes: [0])
        }
        log("Reset to Apple defaults")
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

        // Probe temperature keys across all known Apple Silicon AND Intel generations.
        // Keys that don't exist on a given machine fail fast and are skipped.
        // Format is auto-detected per key via getKeyInfo() — no hardcoded assumptions.
        var temps: [String: Float] = [:]

        let thermalKeys: [String] = [
            // CPU — Apple Silicon aggregate
            "TCDX", "TCHP", "TCMb",
            // CPU — Apple Silicon per-core (Tp prefix)
            "Tp01", "Tp02", "Tp03", "Tp04", "Tp05", "Tp06", "Tp07", "Tp08",
            "Tp09", "Tp0A", "Tp0B", "Tp0C", "Tp0D", "Tp0F", "Tp0G", "Tp0H",
            "Tp0J", "Tp0L", "Tp0P", "Tp0S", "Tp0T", "Tp0W", "Tp0X", "Tp0b",
            // CPU — Intel
            "TC0P", "TC0H", "TC0D", "TC0E", "TC0F", "TC0c", "TCXC", "TCXc",
            "TC1C", "TC1c", "TC2C", "TC2c", "TC3c", "TC4c", "TC5c", "TC6c", "TC7c", "TC8c", "TC9c",
            "TCS0", "TCS1", "TCS2", "TCS3",
            // GPU — Apple Silicon (flt)
            "Tg05", "Tg0D", "Tg0L", "Tg0T", "Tg0f", "Tg0j",
            // GPU — Apple Silicon M5 (ioft)
            "TG0B", "TG0H", "TG0V",
            // GPU — Intel (discrete)
            "TG0P", "TG0D", "TG0T", "TCGC",
            // Memory — Apple Silicon
            "Tm02", "Tm06", "Tm08", "Tm09", "TRDX", "TMVR",
            // Memory — Intel
            "Tm0P", "TM0P", "TM0S",
            // Power delivery
            "TPDX",
            // SSD
            "TH0x", "TH0A", "TH0B", "TH0P",
            // Ambient
            "TAOL", "TA0P", "TA0S", "TA0V", "TA0p",
            // Proximity / misc
            "TS0P", "Ts0P", "TI0P",
            // Battery
            "TB0T",
            // Intel power supply (iMac, Mac Pro)
            "Tp0P",
        ]

        for key in thermalKeys {
            let result = smc.readKey(key)
            guard result.success else { continue }

            guard let info = smc.getKeyInfo(key) else { continue }
            let temp: Float
            switch info.type {
            case "flt ":
                temp = smcBytesToFloat(result.bytes, size: result.size)
            case "sp78":
                temp = sp78BytesToFloat(result.bytes, size: result.size)
            case "ioft":
                temp = ioftBytesToFloat(result.bytes)
            default:
                continue
            }

            if temp > 0 && temp < 150 {
                temps[key] = (temp * 10).rounded() / 10
            }
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
        let arch = MachineArchitecture.current == .applesilicon ? "Apple Silicon" : "Intel"
        let ftst = hasFtst ? "yes (M1-M4 path)" : "no (M5+ direct mode)"
        let modeKey = modeKeyTemplate == SMCFanKey.modeLower ? "F%dmd (lowercase)" : "F%dMd (uppercase)"
        return "Architecture: \(arch), Ftst unlock: \(ftst), Mode key: \(modeKey)"
    }

    // MARK: - Private Helpers

    private func readFanFloat(_ fan: Int, template: String) -> Float {
        let key = SMCFanKey.key(template, fan: fan)
        let result = smc.readKey(key)
        guard result.success else { return 0 }

        // Dispatch based on key's actual SMC data type
        if let info = smc.getKeyInfo(key) {
            switch info.type {
            case "fpe2":
                return fpe2BytesToFloat(result.bytes, size: result.size)
            case "sp78":
                return sp78BytesToFloat(result.bytes, size: result.size)
            default:
                return smcBytesToFloat(result.bytes, size: result.size)
            }
        }
        return smcBytesToFloat(result.bytes, size: result.size)
    }

    /// Write a Float value to a fan key using the correct encoding for this hardware.
    private func writeFanFloat(_ key: String, value: Float) -> Bool {
        if let info = smc.getKeyInfo(key) {
            switch info.type {
            case "fpe2":
                return smc.writeKey(key, bytes: floatToFpe2Bytes(value))
            default:
                return smc.writeKey(key, bytes: floatToSMCBytes(value))
            }
        }
        return smc.writeKey(key, bytes: floatToSMCBytes(value))
    }

    private func log(_ message: String) {
        TFLogger.shared.fan(message)
    }
}
