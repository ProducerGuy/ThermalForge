//
//  FanControl.swift
//  ThermalForge
//
//  Core fan control operations: unlock, set speed, reset, status, discover.
//

import Darwin
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

/// Apple thermal pressure levels exposed via ProcessInfo.thermalState.
/// Maps directly to ProcessInfo.ThermalState enum.
public enum ThermalPressure: String, Codable, Equatable {
    case nominal  = "nominal"
    case fair     = "fair"
    case serious  = "serious"
    case critical = "critical"
}

/// System memory pressure levels from host_statistics64.
public enum MemoryPressure: String, Codable, Equatable {
    case normal   = "normal"
    case warning  = "warning"
    case critical = "critical"
    case unknown  = "unknown"
}

public struct PowerDraw: Encodable {
    /// System total package power (watts). SMC key PSTR.
    public let packageWatts: Float?
    /// CPU power draw (watts). SMC key PCPT.
    public let cpuWatts: Float?
    /// GPU power draw (watts). SMC key PCPG.
    public let gpuWatts: Float?

    public init(packageWatts: Float?, cpuWatts: Float?, gpuWatts: Float?) {
        self.packageWatts = packageWatts
        self.cpuWatts = cpuWatts
        self.gpuWatts = gpuWatts
    }
}

public struct ThermalStatus: Encodable {
    public let fans: [FanStatus]
    public let temperatures: [String: Float]
    /// Package + CPU + GPU power draw in watts (nil if SMC keys unavailable)
    public let power: PowerDraw
    /// Apple thermal pressure state
    public let thermalPressure: ThermalPressure
    /// System memory pressure
    public let memoryPressure: MemoryPressure
    /// Memory used and total in GB
    public let memoryUsedGB: Double
    public let memoryTotalGB: Double
    /// Ambient temperature (nil if not available) — used for Delta-T calculations
    public let ambientTemp: Float?
    /// GPU utilization % (nil if IOReport unavailable)
    public let gpuPercent: Double?
    /// Neural Engine utilization % (nil if IOReport unavailable)
    public let anePercent: Double?

    public init(fans: [FanStatus], temperatures: [String: Float],
                power: PowerDraw = PowerDraw(packageWatts: nil, cpuWatts: nil, gpuWatts: nil),
                thermalPressure: ThermalPressure = .nominal,
                memoryPressure: MemoryPressure = .normal,
                memoryUsedGB: Double = 0,
                memoryTotalGB: Double = 0,
                ambientTemp: Float? = nil,
                gpuPercent: Double? = nil,
                anePercent: Double? = nil) {
        self.fans = fans
        self.temperatures = temperatures
        self.power = power
        self.thermalPressure = thermalPressure
        self.memoryPressure = memoryPressure
        self.memoryUsedGB = memoryUsedGB
        self.memoryTotalGB = memoryTotalGB
        self.ambientTemp = ambientTemp
        self.gpuPercent = gpuPercent
        self.anePercent = anePercent
    }

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
        var temps: [String: Float] = [:]

        // All known CPU/GPU/memory/misc thermal keys (flt type, 4 bytes)
        let fltKeys: [String] = [
            // CPU — aggregate (M5 Max verified)
            "TCDX", "TCHP", "TCMb",
            // CPU — per-core (Tp prefix, present across M1-M5 with varying mappings)
            "Tp01", "Tp02", "Tp03", "Tp04", "Tp05", "Tp06", "Tp07", "Tp08",
            "Tp09", "Tp0A", "Tp0B", "Tp0C", "Tp0D", "Tp0F", "Tp0G", "Tp0H",
            "Tp0J", "Tp0L", "Tp0P", "Tp0S", "Tp0T", "Tp0W", "Tp0X", "Tp0b",
            // GPU (flt type — M1 through M4)
            "Tg05", "Tg0D", "Tg0L", "Tg0T", "Tg0f", "Tg0j",
            // Memory
            "Tm02", "Tm06", "Tm08", "Tm09",
            "TRDX", "TMVR",
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

        for key in fltKeys {
            let result = smc.readKey(key)
            if result.success && result.size == 4 {
                let temp = smcBytesToFloat(result.bytes, size: result.size)
                if temp > 0 && temp < 150 {
                    temps[key] = (temp * 10).rounded() / 10
                }
            }
        }

        // ioft type (16.16 fixed-point, 8 bytes) — GPU temps on M5 Max
        let ioftKeys = ["TG0B", "TG0H", "TG0V"]

        for key in ioftKeys {
            let result = smc.readKey(key)
            if result.success && result.size == 8 {
                let temp = ioftBytesToFloat(result.bytes)
                if temp > 0 && temp < 150 {
                    temps[key] = (temp * 10).rounded() / 10
                }
            }
        }

        // MARK: Power Draw (flt type, 4 bytes)
        // PSTR = system package power, PCPT = CPU power, PCPG = GPU power
        // Keys may be absent on older hardware — nil if not present.
        let packageWatts = readPowerKey("PSTR")
        let cpuWatts     = readPowerKey("PCPT")
        let gpuWatts     = readPowerKey("PCPG")
        let power = PowerDraw(packageWatts: packageWatts, cpuWatts: cpuWatts, gpuWatts: gpuWatts)

        // MARK: Thermal Pressure
        let thermalPressure = Self.currentThermalPressure()

        // MARK: Memory Pressure + Usage
        let (memoryPressure, memUsedGB, memTotalGB) = Self.currentMemoryStats()

        // MARK: Ambient Temperature
        let ambientTemp = temps["TAOL"] ?? temps["TA0P"]

        // MARK: GPU + ANE utilization via IOReport
        let usage = UsageMonitor.shared.sample()

        return ThermalStatus(
            fans: fans,
            temperatures: temps,
            power: power,
            thermalPressure: thermalPressure,
            memoryPressure: memoryPressure,
            memoryUsedGB: memUsedGB,
            memoryTotalGB: memTotalGB,
            ambientTemp: ambientTemp,
            gpuPercent: usage?.gpuPercent,
            anePercent: usage?.anePercent
        )
    }

    // MARK: - Power Key Reader

    /// Read a 4-byte flt power key (watts). Returns nil if the key doesn't exist or reads zero.
    private func readPowerKey(_ key: String) -> Float? {
        let result = smc.readKey(key)
        guard result.success && result.size == 4 else { return nil }
        let watts = smcBytesToFloat(result.bytes, size: result.size)
        guard watts > 0 && watts < 1000 else { return nil } // sanity range
        return (watts * 10).rounded() / 10
    }

    // MARK: - System State

    /// Apple thermal pressure from ProcessInfo.ThermalState.
    private static func currentThermalPressure() -> ThermalPressure {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return .nominal
        case .fair:     return .fair
        case .serious:  return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    /// System memory pressure + used/total GB via host_statistics64.
    /// Returns (pressure, usedGB, totalGB).
    private static func currentMemoryStats() -> (MemoryPressure, Double, Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (.unknown, 0, 0) }

        let pageSize = Double(vm_kernel_page_size)
        let totalGB  = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824

        // Used = wired + active + compressor (compressed pages count as used memory)
        let usedPages = stats.wire_count + stats.active_count + stats.compressor_page_count
        let usedGB = Double(usedPages) * pageSize / 1_073_741_824

        let total = stats.wire_count + stats.active_count + stats.inactive_count
                  + stats.free_count + stats.compressor_page_count
        let pressure: MemoryPressure
        if total > 0 {
            let compressedRatio = Float(stats.compressor_page_count) / Float(total)
            if compressedRatio > 0.90 { pressure = .critical }
            else if compressedRatio > 0.70 { pressure = .warning }
            else { pressure = .normal }
        } else {
            pressure = .normal
        }

        return (pressure, min(usedGB, totalGB), totalGB)
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
