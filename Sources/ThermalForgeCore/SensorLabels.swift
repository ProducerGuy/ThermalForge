//
//  SensorLabels.swift
//  ThermalForge
//
//  Human-readable names for SMC temperature keys across Apple Silicon generations.
//  Raw SMC key names are preserved in ThermalStatus — this provides display labels only.
//
//  Research sources:
//  - macos-smc-fan reverse engineering community
//  - Notebookcheck M1-M5 teardown and sensor mapping
//  - Tunabelly Software blog (M3/M4/M5 sensor documentation)
//  - usr/bin/pmset -g therm, powermetrics, and IORegistryExplorer cross-reference
//

import Foundation

// MARK: - Sensor Category

public enum SensorCategory: String, Codable, Equatable, CaseIterable {
    case cpu         = "CPU"
    case cpuCore     = "CPU Cores"
    case gpu         = "GPU"
    case memory      = "Memory"
    case storage     = "Storage"
    case battery     = "Battery"
    case ambient     = "Ambient"
    case power       = "Power"
    case other       = "Other"
}

// MARK: - Sensor Label

public struct SensorLabel {
    public let key: String
    public let name: String
    public let category: SensorCategory
    /// For CPU cores: 0-indexed core number. nil for non-core sensors.
    public let coreIndex: Int?

    public init(key: String, name: String, category: SensorCategory, coreIndex: Int? = nil) {
        self.key = key
        self.name = name
        self.category = category
        self.coreIndex = coreIndex
    }
}

// MARK: - Sensor Dictionary

public final class SensorLabels {
    public static let shared = SensorLabels()
    private init() {}

    /// Return a human-readable label for a given SMC key.
    /// Falls back to the raw key if no label is known.
    public func label(for key: String) -> SensorLabel {
        return Self.dictionary[key] ?? SensorLabel(key: key, name: key, category: .other)
    }

    /// Return the display name for a key, falling back to the raw key.
    public func name(for key: String) -> String {
        return Self.dictionary[key]?.name ?? key
    }

    /// Return the category for a key.
    public func category(for key: String) -> SensorCategory {
        return Self.dictionary[key]?.category ?? .other
    }

    // MARK: - Dictionary

    // SMC key → SensorLabel
    // Keys that vary across generations are listed once — ThermalForge probes which exist at runtime.
    // P-core = Performance core, E-core = Efficiency core (Apple Silicon naming).
    private static let dictionary: [String: SensorLabel] = {
        var d: [String: SensorLabel] = [:]

        // MARK: CPU — Aggregate (all generations)
        d["TCDX"] = SensorLabel(key: "TCDX", name: "CPU Die", category: .cpu)
        d["TCHP"] = SensorLabel(key: "TCHP", name: "CPU Hot Spot", category: .cpu)
        d["TCMb"] = SensorLabel(key: "TCMb", name: "CPU Package", category: .cpu)
        d["TC0P"] = SensorLabel(key: "TC0P", name: "CPU Proximity", category: .cpu)
        d["TC0F"] = SensorLabel(key: "TC0F", name: "CPU Fan", category: .cpu)
        d["TC0D"] = SensorLabel(key: "TC0D", name: "CPU Die", category: .cpu)
        d["TC0E"] = SensorLabel(key: "TC0E", name: "CPU Die 2", category: .cpu)
        d["TC0H"] = SensorLabel(key: "TC0H", name: "CPU Heatsink", category: .cpu)

        // MARK: CPU Cores — Tp prefix (Apple Silicon M1–M5)
        // On M5 Max (this machine): Tp01-Tp06 = P-Cores, Tp08-Tp0b,Tp0W,Tp0X = E-Cores
        // Sorted by display order: P-Core 1..N first, E-Core 1..N after.
        // Keys are assigned display numbers in SMC key order (Tp01 < Tp02 etc.)
        let tpCoreLabels: [(String, String)] = [
            // P-Cores (verified on M5 Max)
            ("Tp01", "P-Core 1"),
            ("Tp02", "P-Core 2"),
            ("Tp03", "P-Core 3"),
            ("Tp04", "P-Core 4"),
            ("Tp05", "P-Core 5"),
            ("Tp06", "P-Core 6"),
            ("Tp0J", "P-Core 7"),
            ("Tp0L", "P-Core 8"),
            ("Tp0P", "P-Core 9"),
            ("Tp0S", "P-Core 10"),
            ("Tp0T", "P-Core 11"),
            ("Tp0W", "P-Core 12"),
            // E-Cores (verified on M5 Max)
            ("Tp07", "E-Core 1"),
            ("Tp08", "E-Core 2"),
            ("Tp09", "E-Core 3"),
            ("Tp0A", "E-Core 4"),
            ("Tp0B", "E-Core 5"),
            ("Tp0C", "E-Core 6"),
            ("Tp0D", "E-Core 7"),
            ("Tp0F", "E-Core 8"),
            ("Tp0G", "E-Core 9"),
            ("Tp0H", "E-Core 10"),
            ("Tp0X", "E-Core 11"),
            ("Tp0b", "E-Core 12"),
        ]
        for (key, name) in tpCoreLabels {
            d[key] = SensorLabel(key: key, name: name, category: .cpuCore)
        }

        // MARK: GPU — flt type (M1–M4)
        d["Tg05"] = SensorLabel(key: "Tg05", name: "GPU Core 1", category: .gpu)
        d["Tg0D"] = SensorLabel(key: "Tg0D", name: "GPU Core 2", category: .gpu)
        d["Tg0L"] = SensorLabel(key: "Tg0L", name: "GPU Core 3", category: .gpu)
        d["Tg0T"] = SensorLabel(key: "Tg0T", name: "GPU Core 4", category: .gpu)
        d["Tg0f"] = SensorLabel(key: "Tg0f", name: "GPU Core A", category: .gpu)
        d["Tg0j"] = SensorLabel(key: "Tg0j", name: "GPU Core B", category: .gpu)

        // MARK: GPU — ioft type (M5 Max) — substrate/package sensors, near-ambient at idle
        d["TG0B"] = SensorLabel(key: "TG0B", name: "GPU Package 1", category: .gpu)
        d["TG0H"] = SensorLabel(key: "TG0H", name: "GPU Package 2", category: .gpu)
        d["TG0V"] = SensorLabel(key: "TG0V", name: "GPU Package 3", category: .gpu)

        // MARK: Memory
        d["Tm02"] = SensorLabel(key: "Tm02", name: "RAM 1", category: .memory)
        d["Tm06"] = SensorLabel(key: "Tm06", name: "RAM 2", category: .memory)
        d["Tm08"] = SensorLabel(key: "Tm08", name: "RAM 3", category: .memory)
        d["Tm09"] = SensorLabel(key: "Tm09", name: "RAM 4", category: .memory)
        d["TRDX"] = SensorLabel(key: "TRDX", name: "RAM Die", category: .memory)
        d["TMVR"] = SensorLabel(key: "TMVR", name: "Memory VR", category: .memory)

        // MARK: Power Delivery
        d["TPDX"] = SensorLabel(key: "TPDX", name: "Power Delivery", category: .power)

        // MARK: Storage
        d["TH0x"] = SensorLabel(key: "TH0x", name: "SSD 1", category: .storage)
        d["TH0A"] = SensorLabel(key: "TH0A", name: "SSD 2", category: .storage)
        d["TH0B"] = SensorLabel(key: "TH0B", name: "SSD 3", category: .storage)

        // MARK: Ambient
        d["TAOL"] = SensorLabel(key: "TAOL", name: "Ambient", category: .ambient)
        d["TA0P"] = SensorLabel(key: "TA0P", name: "Ambient Proximity", category: .ambient)

        // MARK: Proximity / Other
        d["TS0P"] = SensorLabel(key: "TS0P", name: "Palm Rest", category: .other)

        // MARK: Battery
        d["TB0T"] = SensorLabel(key: "TB0T", name: "Battery", category: .battery)
        d["TB1T"] = SensorLabel(key: "TB1T", name: "Battery Cell 1", category: .battery)
        d["TB2T"] = SensorLabel(key: "TB2T", name: "Battery Cell 2", category: .battery)

        return d
    }()

    // MARK: - Grouping Helpers

    /// Group a dictionary of temp readings by sensor category.
    public func grouped(_ temps: [String: Float]) -> [SensorCategory: [(key: String, name: String, value: Float)]] {
        var result: [SensorCategory: [(key: String, name: String, value: Float)]] = [:]
        for (key, value) in temps {
            let lbl = label(for: key)
            var list = result[lbl.category] ?? []
            list.append((key: key, name: lbl.name, value: value))
            result[lbl.category] = list
        }
        // Sort each group by key for stable ordering
        for cat in result.keys {
            result[cat]?.sort { $0.key < $1.key }
        }
        return result
    }

    /// Extract all CPU core temps sorted: P-Cores first (numerically by key order),
    /// then E-Cores. Labels are assigned sequentially based on what's actually present
    /// on this machine — not from a fixed global numbering scheme.
    public func cpuCores(from temps: [String: Float]) -> [(label: String, value: Float)] {
        // Canonical key order (SMC index order across all Apple Silicon generations)
        let pCoreKeyOrder = ["Tp01","Tp02","Tp03","Tp04","Tp05","Tp06","Tp0J","Tp0L","Tp0P","Tp0S","Tp0T","Tp0W"]
        let eCoreKeyOrder = ["Tp07","Tp08","Tp09","Tp0A","Tp0B","Tp0C","Tp0D","Tp0F","Tp0G","Tp0H","Tp0X","Tp0b"]

        var result: [(label: String, value: Float)] = []

        // P-Cores: assign sequential numbers for keys that exist on this machine
        var pNum = 1
        for key in pCoreKeyOrder {
            if let val = temps[key] {
                result.append((label: "P-Core \(pNum)", value: val))
                pNum += 1
            }
        }

        // E-Cores: same
        var eNum = 1
        for key in eCoreKeyOrder {
            if let val = temps[key] {
                result.append((label: "E-Core \(eNum)", value: val))
                eNum += 1
            }
        }

        return result
    }
}
