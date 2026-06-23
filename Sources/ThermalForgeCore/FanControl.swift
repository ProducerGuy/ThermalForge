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

public struct ThermalStatus: Encodable, Equatable {
    public let fans: [FanStatus]
    public let temperatures: [String: Float]

    public struct FanStatus: Encodable, Equatable {
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
    private let smc: SMCReading
    /// Which mode key works on this hardware (detected at init)
    private let modeKeyTemplate: String
    /// Whether Ftst unlock is available (M1-M4) or not (M5+)
    private let hasFtst: Bool

    // Hardware facts that never change for a session — read once, then cached.
    // FanControl is only ever accessed serially (monitor queue / daemon smcLock /
    // CLI), so these lazy caches need no locking of their own.
    private var cachedFanCount: Int?
    private var cachedLimits: [Int: (min: Float, max: Float)] = [:]
    private var liveTempKeys: [LiveTempKey]?

    /// Creates a FanControl backed by the real SMC. Throws if no SMC is present.
    public convenience init() throws {
        guard let connection = SMCConnection() else {
            throw ThermalForgeError.smcConnectionFailed
        }
        self.init(smc: connection)
    }

    /// Designated init — accepts any SMC backend (real or a test fake).
    public init(smc: SMCReading) {
        self.smc = smc

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
        if let cached = cachedFanCount { return cached }
        let result = smc.readKey(SMCFanKey.count)
        guard result.success, !result.bytes.isEmpty else {
            throw ThermalForgeError.readFailed(SMCFanKey.count)
        }
        let count = Int(result.bytes[0])
        cachedFanCount = count
        return count
    }

    // MARK: - Read Fan Info

    public func fanInfo(_ index: Int) throws -> FanInfo {
        let actual = readFanFloat(index, template: SMCFanKey.actual)
        let target = readFanFloat(index, template: SMCFanKey.target)
        let limits = fanLimits(index)

        return FanInfo(
            index: index,
            actualRPM: actual,
            targetRPM: target,
            minRPM: limits.min,
            maxRPM: limits.max,
            mode: readMode(index)
        )
    }

    /// Per-fan min/max RPM are firmware constants — read once, then cached.
    /// Only cached once a valid maximum (> 0) is seen, so a transient zero read
    /// at startup isn't latched.
    private func fanLimits(_ index: Int) -> (min: Float, max: Float) {
        if let cached = cachedLimits[index] { return cached }
        let minimum = readFanFloat(index, template: SMCFanKey.minimum)
        let maximum = readFanFloat(index, template: SMCFanKey.maximum)
        if maximum > 0 { cachedLimits[index] = (minimum, maximum) }
        return (minimum, maximum)
    }

    private func readMode(_ index: Int) -> String {
        let modeResult = smc.readKey(SMCFanKey.key(modeKeyTemplate, fan: index))
        let modeValue = modeResult.success && !modeResult.bytes.isEmpty ? modeResult.bytes[0] : 0
        switch modeValue {
        case 0: return "auto"
        case 1: return "manual"
        case 3: return "system"
        default: return "unknown(\(modeValue))"
        }
    }

    /// Min/max RPM of the primary fan (fan 0), cached. Falls back to typical
    /// Apple Silicon values when no fan is present or limits read as zero.
    public func primaryFanLimits() -> (minRPM: Float, maxRPM: Float) {
        guard let count = try? fanCount(), count > 0 else { return (2317, 7826) }
        let limits = fanLimits(0)
        return (limits.min > 0 ? limits.min : 2317, limits.max > 0 ? limits.max : 7826)
    }

    // MARK: - Unlock

    /// Unlock fans for manual control.
    /// On M1-M4: writes Ftst=1, then polls until mode write succeeds.
    /// On M5+: Ftst doesn't exist, attempts direct mode write.
    private func unlockFans(count: Int) throws {
        // Fast path: if every fan is already in manual mode the unlock happened
        // on an earlier command — skip the Ftst write + 0.5s sleep + poll loop.
        // (Ftst/mode stay set until resetAuto, so thermalmonitord stays off.)
        if count > 0 && (0..<count).allSatisfy({ isManualMode($0) }) {
            return
        }

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
            if isManualMode(i) { continue }   // already manual — skip the poll loop
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

        // Read every live sensor (the subset present on this machine). Labels
        // use the raw SMC key name — no assumptions about what a key means on
        // hardware we haven't verified.
        var temps: [String: Float] = [:]
        for liveKey in liveTemperatureKeys() {
            if let temp = readTemp(liveKey) {
                temps[liveKey.key] = temp
            }
        }

        return ThermalStatus(fans: fans, temperatures: temps)
    }

    // MARK: - Temperatures

    /// Which subsystem a temperature key reports — used to keep the hot control
    /// read down to just the sensors the controller and 95°C override consume.
    private enum TempGroup { case cpu, gpu, other }
    private struct LiveTempKey { let key: String; let isIoft: Bool; let group: TempGroup }
    private struct TempCandidate { let key: String; let isIoft: Bool; let group: TempGroup }

    /// All known thermal keys across M1–M5. Probed once to find the live subset.
    /// Grouping mirrors the prefixes the monitor uses: CPU = TC/Tp, GPU = TG/Tg.
    private static let tempCandidates: [TempCandidate] = {
        func flt(_ keys: [String], _ group: TempGroup) -> [TempCandidate] {
            keys.map { TempCandidate(key: $0, isIoft: false, group: group) }
        }
        var c: [TempCandidate] = []
        // CPU — aggregate (M5 Max) + per-core (Tp, M1–M5)
        c += flt(["TCDX", "TCHP", "TCMb",
                  "Tp01", "Tp02", "Tp03", "Tp04", "Tp05", "Tp06", "Tp07", "Tp08",
                  "Tp09", "Tp0A", "Tp0B", "Tp0C", "Tp0D", "Tp0F", "Tp0G", "Tp0H",
                  "Tp0J", "Tp0L", "Tp0P", "Tp0S", "Tp0T", "Tp0W", "Tp0X", "Tp0b"], .cpu)
        // GPU — flt (M1–M4)
        c += flt(["Tg05", "Tg0D", "Tg0L", "Tg0T", "Tg0f", "Tg0j"], .gpu)
        // Memory / power / SSD / ambient / proximity / battery — display only
        c += flt(["Tm02", "Tm06", "Tm08", "Tm09", "TRDX", "TMVR", "TPDX",
                  "TH0x", "TH0A", "TH0B", "TAOL", "TA0P", "TS0P", "TB0T"], .other)
        // GPU — ioft 16.16 fixed-point, 8 bytes (M5 Max)
        c += ["TG0B", "TG0H", "TG0V"].map { TempCandidate(key: $0, isIoft: true, group: .gpu) }
        return c
    }()

    /// The temperature keys actually present on this machine. Probed once (a
    /// non-empty result is cached); absent keys are never read again, so the
    /// hot path stops paying IOKit calls for other generations' sensors.
    private func liveTemperatureKeys() -> [LiveTempKey] {
        if let cached = liveTempKeys, !cached.isEmpty { return cached }
        var live: [LiveTempKey] = []
        for cand in Self.tempCandidates {
            let result = smc.readKey(cand.key)
            let present = cand.isIoft ? (result.success && result.size == 8)
                                      : (result.success && result.size == 4)
            if present {
                live.append(LiveTempKey(key: cand.key, isIoft: cand.isIoft, group: cand.group))
            }
        }
        if !live.isEmpty { liveTempKeys = live }
        return live
    }

    private func readTemp(_ liveKey: LiveTempKey) -> Float? {
        let result = smc.readKey(liveKey.key)
        guard result.success else { return nil }
        let temp = liveKey.isIoft
            ? ioftBytesToFloat(result.bytes)
            : smcBytesToFloat(result.bytes, size: result.size)
        guard temp > 0 && temp < 150 else { return nil }
        return (temp * 10).rounded() / 10
    }

    /// Cheap read for the control loop: peak CPU and GPU temperature only.
    /// Skips the ~14 display-only sensors (RAM/SSD/ambient/…) and all fan reads.
    /// Returns nil when no CPU/GPU sensor could be read (treat as a failed tick).
    public func controlTemps() -> (cpu: Float, gpu: Float)? {
        let keys = liveTemperatureKeys()
        guard !keys.isEmpty else { return nil }
        var cpu: Float = 0
        var gpu: Float = 0
        var read = false
        for liveKey in keys where liveKey.group != .other {
            guard let temp = readTemp(liveKey) else { continue }
            read = true
            if liveKey.group == .cpu { cpu = max(cpu, temp) } else { gpu = max(gpu, temp) }
        }
        return read ? (cpu, gpu) : nil
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

    /// True if the fan is currently in manual mode (mode key == 1).
    private func isManualMode(_ index: Int) -> Bool {
        let modeKey = SMCFanKey.key(modeKeyTemplate, fan: index)
        let result = smc.readKey(modeKey)
        return result.success && !result.bytes.isEmpty && result.bytes[0] == 1
    }

    private func log(_ message: String) {
        TFLogger.shared.fan(message)
    }
}
