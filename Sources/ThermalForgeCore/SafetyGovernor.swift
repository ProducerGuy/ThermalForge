import Foundation

/// The thermal safety floor, rebuilt for M4-class machines.
///
/// The old floor compared the peak over ALL TC/Tp/TG/Tg keys against a single
/// 95°C threshold while a below-max hold was active. On Apple Silicon laptops
/// that is unusable: hotspot-class keys legitimately read 96-113°C under
/// sustained load while macOS itself stays nominal (fans near minimum, thermal
/// pressure Nominal, no thermal or performance warnings ever recorded). Every
/// manual hold was overridden to max within seconds and re-armed forever.
///
/// The governor:
///  - uses macOS thermal pressure as the PRIMARY signal (Serious/Critical trip
///    immediately; Fair must persist) — Apple's own model already accounts for
///    hotspot readings;
///  - adds calibrated backstops per sensor class: hotspot-class keys at 118°C
///    sustained 10s, judged by the second-highest reading so a single glitchy
///    key can neither trip nor block a clear; structure at 95°C/30s; battery at
///    50°C/60s. On older generations (M1-M3) these backstops may never fire
///    before hardware throttling — that is fine; pressure is the primary guard;
///  - sanitizes readings (1-130°C) before classifying;
///  - latches on a trip and only clears after pressure is NOMINAL and every
///    class sits 10°C below its threshold, sustained;
///  - after repeated trips within a window, stops the auto-restore cycle and
///    asks the caller to leave the fans with Apple (a "stayAuto" decision).
///
/// All persistence windows are in SECONDS, driven by a caller-supplied elapsed
/// time, so they cannot be rescaled by a change in caller cadence (the daemon
/// ticks at 1s, the app monitor at 0.1s).
public struct SafetyGovernor: Sendable {

    // MARK: Thresholds (calibrated on a MacBook Pro 14" M4 Max, macOS 27)

    public static let hotspotThreshold: Float = 118.0
    public static let hotspotPersistSeconds: Double = 10
    public static let structureThreshold: Float = 95.0
    public static let structurePersistSeconds: Double = 30
    public static let batteryThreshold: Float = 50.0
    public static let batteryPersistSeconds: Double = 60

    /// macOS thermal pressure: Serious/Critical trip immediately; Fair must persist.
    public static let fairPersistSeconds: Double = 30

    /// Clear a latch only at Nominal pressure with every class this far below
    /// its threshold…
    public static let clearMargin: Float = 10.0
    /// …for this long.
    public static let clearPersistSeconds: Double = 30

    /// Consecutive empty sensor sweeps while a hold is active = blind hold = unsafe.
    public static let emptySecondsToTrip: Double = 5

    /// Repeated trips inside this window stop the auto-restore cycle: after
    /// `retripLimit` trips within `retripWindowSeconds`, the governor leaves the
    /// fans with Apple and asks the user to re-apply deliberately.
    public static let retripWindowSeconds: Double = 600
    public static let retripLimit = 3

    /// Readings outside this range are garbage (placeholder sentinels, decode
    /// artifacts) and are dropped before any class math.
    public static let readingFloorCelsius: Float = 1.0
    public static let readingCeilingCelsius: Float = 130.0

    public enum Action: Equatable, Sendable {
        case none
        case engage(String)   // trip: caller applies its protective action
        case restore(String)  // latch cleared: caller may restore the hold
        case stayAuto(String) // cleared after repeated trips: leave fans with Apple
    }

    public private(set) var isLatched: Bool
    private var hotspotOverSeconds = 0.0
    private var structureOverSeconds = 0.0
    private var batteryOverSeconds = 0.0
    private var fairSeconds = 0.0
    private var clearSeconds = 0.0
    private var emptySeconds = 0.0
    private var secondsSinceTrip = 0.0
    private var recentTrips = 0

    public init(isLatched: Bool = false) { self.isLatched = isLatched }

    public mutating func clearLatch() { isLatched = false; resetCounters() }

    private mutating func resetCounters() {
        hotspotOverSeconds = 0; structureOverSeconds = 0; batteryOverSeconds = 0
        fairSeconds = 0; clearSeconds = 0; emptySeconds = 0
    }

    private func classReading(_ samples: [SafetySample], _ cls: SafetySensorClass,
                              secondHighest: Bool) -> Float? {
        let values = samples
            .filter { $0.sensorClass == cls
                      && $0.celsius >= Self.readingFloorCelsius
                      && $0.celsius <= Self.readingCeilingCelsius }
            .map { $0.celsius }.sorted(by: >)
        guard !values.isEmpty else { return nil }
        if secondHighest, values.count >= 2 { return values[1] }
        return values[0]
    }

    /// One evaluation tick. `elapsed` is seconds since the previous call; each
    /// caller measures it so a cadence change cannot rescale the windows.
    public mutating func evaluate(
        samples: [SafetySample],
        pressure: ThermalPressureLevel,
        holdActive: Bool,
        elapsed: Double
    ) -> Action {
        secondsSinceTrip += elapsed

        // --- Latched: only the clear path runs. ------------------------------
        if isLatched {
            let hotspot = classReading(samples, .hotspot, secondHighest: true)
            let structure = classReading(samples, .structure, secondHighest: false)
            let battery = classReading(samples, .battery, secondHighest: false)
            let clear = pressure == .nominal
                && (hotspot.map { $0 <= Self.hotspotThreshold - Self.clearMargin } ?? false)
                && (structure.map { $0 <= Self.structureThreshold - Self.clearMargin } ?? true)
                && (battery.map { $0 <= Self.batteryThreshold - Self.clearMargin } ?? true)
            if clear {
                clearSeconds += elapsed
                if clearSeconds >= Self.clearPersistSeconds {
                    isLatched = false
                    resetCounters()
                    if recentTrips >= Self.retripLimit {
                        recentTrips = 0
                        return .stayAuto("cooled after \(Self.retripLimit)+ trips within \(Int(Self.retripWindowSeconds))s — left on auto; re-apply your setting to re-engage")
                    }
                    return .restore("cooled \(Int(Self.clearPersistSeconds))s at nominal pressure, every class \(Int(Self.clearMargin))C below threshold")
                }
            } else {
                clearSeconds = 0
            }
            return .none
        }

        guard holdActive else {
            resetCounters()
            return .none
        }

        // --- Primary: macOS thermal pressure. Checked before the sensor state:
        // a blind hold cannot wait on the sensor sweep. -----------------------
        switch pressure {
        case .serious, .critical:
            return trip("macOS thermal pressure \(pressure)")
        case .fair:
            fairSeconds += elapsed
            if fairSeconds >= Self.fairPersistSeconds {
                return trip("macOS thermal pressure fair for \(Int(fairSeconds))s")
            }
        case .nominal:
            fairSeconds = 0
        }

        // --- Blind hold: no readable hotspot sensor. --------------------------
        guard let hotspot = classReading(samples, .hotspot, secondHighest: true) else {
            emptySeconds += elapsed
            if emptySeconds >= Self.emptySecondsToTrip {
                return trip("no readable temperature sensors while fans are under manual control")
            }
            return .none
        }
        emptySeconds = 0

        // --- Per-class backstops. --------------------------------------------
        if hotspot >= Self.hotspotThreshold {
            hotspotOverSeconds += elapsed
            if hotspotOverSeconds >= Self.hotspotPersistSeconds {
                return trip(String(format: "hotspot-class sensor at %.1fC for %ds (threshold %.0fC)",
                                   hotspot, Int(hotspotOverSeconds), Self.hotspotThreshold))
            }
        } else { hotspotOverSeconds = 0 }

        if let structure = classReading(samples, .structure, secondHighest: false) {
            if structure >= Self.structureThreshold {
                structureOverSeconds += elapsed
                if structureOverSeconds >= Self.structurePersistSeconds {
                    return trip(String(format: "structure sensor at %.1fC for %ds",
                                       structure, Int(structureOverSeconds)))
                }
            } else { structureOverSeconds = 0 }
        }

        if let battery = classReading(samples, .battery, secondHighest: false) {
            if battery >= Self.batteryThreshold {
                batteryOverSeconds += elapsed
                if batteryOverSeconds >= Self.batteryPersistSeconds {
                    return trip(String(format: "battery at %.1fC for %ds", battery, Int(batteryOverSeconds)))
                }
            } else { batteryOverSeconds = 0 }
        }

        return .none
    }

    private mutating func trip(_ reason: String) -> Action {
        isLatched = true
        recentTrips = secondsSinceTrip < Self.retripWindowSeconds ? recentTrips + 1 : 1
        secondsSinceTrip = 0
        resetCounters()
        return .engage(reason)
    }
}

/// Sensor classes tracked by the safety governor.
public enum SafetySensorClass: String, Sendable, Equatable, CaseIterable {
    case hotspot    // die-adjacent (TC*/Tp*/Tg*/TG* minus the misnamed battery keys)
    case structure  // board / skin / proximity (TS0P for now)
    case battery    // cell temperature (TB*)
}

/// One classified temperature reading handed to the governor.
public struct SafetySample: Sendable, Equatable {
    public let key: String
    public let celsius: Float
    public let sensorClass: SafetySensorClass

    public init(key: String, celsius: Float, sensorClass: SafetySensorClass) {
        self.key = key
        self.celsius = celsius
        self.sensorClass = sensorClass
    }
}

/// ProcessInfo.ThermalState as a comparable ladder.
public enum ThermalPressureLevel: Int, Sendable, Comparable, CustomStringConvertible {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .nominal
        }
    }

    public static func < (lhs: ThermalPressureLevel, rhs: ThermalPressureLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        }
    }
}
