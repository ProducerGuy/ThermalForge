//
//  BatteryMonitor.swift
//  ThermalForge
//
//  Battery health monitoring via IOKit AppleSmartBattery.
//  Reads cycle count, capacity, health condition, charge state,
//  voltage, current, and temperature from the battery service.
//
//  Sources:
//  - IOKit AppleSmartBattery key names (ioreg -l -n AppleSmartBattery)
//  - Apple Technical Note TN2151 (battery properties)
//  - Battery health condition strings from Apple System Information
//

import Foundation
import IOKit

// MARK: - Battery Condition

public enum BatteryCondition: String, Codable, Equatable, Sendable {
    case normal      = "Normal"
    case serviceSoon = "Service Recommended"
    case serviceNow  = "Service Battery"
    case unknown     = "Unknown"

    public init(raw: String?) {
        switch raw {
        case "Normal":              self = .normal
        case "Service Recommended": self = .serviceSoon
        case "Service Battery":     self = .serviceNow
        default:                    self = .unknown
        }
    }

    public var isHealthy: Bool { self == .normal }
}

// MARK: - Battery Health Alert

public enum BatteryAlert: Equatable, Sendable {
    case conditionChanged(BatteryCondition)
    case cycleCountHigh(Int)       // > 500
    case cycleCountVeryHigh(Int)   // > 1000
    case overCurrent
    case overVoltage
    case lowCapacity(Int)          // design capacity % < 80
}

// MARK: - Battery Status

public struct BatteryStatus: Codable, Equatable {
    /// Current charge percentage (0–100)
    public let chargePercent: Int
    /// Is currently charging
    public let isCharging: Bool
    /// Is plugged in (AC connected)
    public let isPluggedIn: Bool
    /// Battery temperature in °C (nil if unavailable)
    public let temperatureC: Float?
    /// Current voltage in mV
    public let voltageMV: Int?
    /// Current amperage in mA (negative = discharging, positive = charging)
    public let amperageMА: Int?
    /// Cycle count
    public let cycleCount: Int?
    /// Current max capacity (mAh)
    public let currentCapacityMAh: Int?
    /// Design capacity (mAh)
    public let designCapacityMAh: Int?
    /// Calculated health percentage (currentCapacity / designCapacity * 100)
    public let healthPercent: Int?
    /// Apple's battery condition string
    public let condition: BatteryCondition
    /// Whether battery is present
    public let isPresent: Bool

    /// Time to full charge in minutes (nil if not charging or unavailable)
    public let timeToFullMinutes: Int?
    /// Time remaining in minutes (nil if charging or unavailable)
    public let timeRemainingMinutes: Int?

    public init(
        chargePercent: Int = 0,
        isCharging: Bool = false,
        isPluggedIn: Bool = false,
        temperatureC: Float? = nil,
        voltageMV: Int? = nil,
        amperageMА: Int? = nil,
        cycleCount: Int? = nil,
        currentCapacityMAh: Int? = nil,
        designCapacityMAh: Int? = nil,
        healthPercent: Int? = nil,
        condition: BatteryCondition = .unknown,
        isPresent: Bool = false,
        timeToFullMinutes: Int? = nil,
        timeRemainingMinutes: Int? = nil
    ) {
        self.chargePercent = chargePercent
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.temperatureC = temperatureC
        self.voltageMV = voltageMV
        self.amperageMА = amperageMА
        self.cycleCount = cycleCount
        self.currentCapacityMAh = currentCapacityMAh
        self.designCapacityMAh = designCapacityMAh
        self.healthPercent = healthPercent
        self.condition = condition
        self.isPresent = isPresent
        self.timeToFullMinutes = timeToFullMinutes
        self.timeRemainingMinutes = timeRemainingMinutes
    }
}

// MARK: - BatteryMonitor

/// Reads battery status from IOKit's AppleSmartBattery service.
/// Not available on Mac Pro / Mac mini (no internal battery).
public final class BatteryMonitor {

    public static let shared = BatteryMonitor()
    private init() {}

    // MARK: - Read

    /// Read current battery status. Returns nil on desktop Macs with no battery.
    public func read() -> BatteryStatus? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        guard let props = readProperties(service) else { return nil }

        let isPresent = props["BatteryInstalled"] as? Bool ?? false
        guard isPresent else {
            return BatteryStatus(isPresent: false)
        }

        // Charge
        let chargePercent = props["CurrentCapacity"] as? Int ?? 0
        let isCharging    = props["IsCharging"] as? Bool ?? false
        let isPluggedIn   = props["ExternalConnected"] as? Bool ?? false

        // Voltage & current
        let voltageMV   = props["Voltage"] as? Int
        let amperageMА  = props["InstantAmperage"] as? Int

        // Capacity — on Apple Silicon MaxCapacity is reported as a percentage (0–100)
        // DesignCapacity is in mAh. Health% = MaxCapacity directly when it's ≤ 100,
        // otherwise compute as (MaxCapacity / DesignCapacity * 100).
        let currentCapMAh = props["MaxCapacity"] as? Int
        let designCapMAh  = props["DesignCapacity"] as? Int
        var healthPct: Int? = nil
        if let maxCap = currentCapMAh {
            if maxCap <= 100 {
                // MaxCapacity is already a percentage (Apple Silicon behaviour)
                healthPct = maxCap
            } else if let desCap = designCapMAh, desCap > 0 {
                // Older format: both in mAh
                healthPct = min(100, Int((Float(maxCap) / Float(desCap) * 100).rounded()))
            }
        }

        // Temperature (reported in 1/100 °C on some firmware, 1/10 on others)
        // AppleSmartBattery reports in units of 0.01°C (hundredths).
        var tempC: Float? = nil
        if let rawTemp = props["Temperature"] as? Int, rawTemp > 0 {
            // Apple reports battery temp as integer in units of 0.01°C
            // e.g. 2950 = 29.50°C. Sanity check: realistic range 0–80°C = 0–8000 raw.
            let candidate = Float(rawTemp) / 100.0
            if candidate > 0 && candidate < 80 {
                tempC = (candidate * 10).rounded() / 10
            }
        }

        // Cycle count
        let cycleCount = props["CycleCount"] as? Int

        // Condition
        let conditionStr = props["BatteryHealthCondition"] as? String
                        ?? props["BatteryHealth"] as? String
        let condition = BatteryCondition(raw: conditionStr)

        // Time estimates
        let timeToFull      = props["AvgTimeToFull"] as? Int      // minutes; 65535 = unknown
        let timeRemaining   = props["AvgTimeToEmpty"] as? Int     // minutes; 65535 = unknown

        return BatteryStatus(
            chargePercent: chargePercent,
            isCharging: isCharging,
            isPluggedIn: isPluggedIn,
            temperatureC: tempC,
            voltageMV: voltageMV,
            amperageMА: amperageMА,
            cycleCount: cycleCount,
            currentCapacityMAh: currentCapMAh,
            designCapacityMAh: designCapMAh,
            healthPercent: healthPct,
            condition: condition,
            isPresent: isPresent,
            timeToFullMinutes: (timeToFull != nil && timeToFull! < 65535) ? timeToFull : nil,
            timeRemainingMinutes: (timeRemaining != nil && timeRemaining! < 65535) ? timeRemaining : nil
        )
    }

    // MARK: - Alerts

    /// Compare previous and new status, return any alerts that should be surfaced.
    public func alerts(previous: BatteryStatus?, current: BatteryStatus) -> [BatteryAlert] {
        guard current.isPresent else { return [] }
        var result: [BatteryAlert] = []

        // Condition change
        if let prev = previous, prev.condition != current.condition {
            result.append(.conditionChanged(current.condition))
        }

        // Cycle count thresholds (only fire once when crossing)
        if let cycles = current.cycleCount {
            let prevCycles = previous?.cycleCount ?? 0
            if cycles > 1000 && prevCycles <= 1000 {
                result.append(.cycleCountVeryHigh(cycles))
            } else if cycles > 500 && prevCycles <= 500 {
                result.append(.cycleCountHigh(cycles))
            }
        }

        // Low capacity (first read only — don't repeat)
        if previous == nil, let hp = current.healthPercent, hp < 80 {
            result.append(.lowCapacity(hp))
        }

        // Over-current: amperage magnitude > 10000 mA is unrealistic
        if let amps = current.amperageMА, abs(amps) > 10000 {
            if previous?.amperageMА.map({ abs($0) <= 10000 }) ?? true {
                result.append(.overCurrent)
            }
        }

        // Over-voltage: > 17V is unrealistic for MacBook battery
        if let mv = current.voltageMV, mv > 17000 {
            if previous?.voltageMV.map({ $0 <= 17000 }) ?? true {
                result.append(.overVoltage)
            }
        }

        return result
    }

    // MARK: - Private

    private func readProperties(_ service: io_service_t) -> [String: Any]? {
        var props: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)
        guard result == kIOReturnSuccess, let dict = props else { return nil }
        return dict.takeRetainedValue() as? [String: Any]
    }
}
