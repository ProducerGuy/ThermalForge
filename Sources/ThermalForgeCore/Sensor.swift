//
//  Sensor.swift
//  ThermalForge
//
//  The temperature categories ThermalForge already surfaces — the same CPU/GPU/RAM/
//  SSD/Ambient groupings the menu bar's TEMPERATURES rows show — reused here so a
//  dual-sensor Custom Curve can be built from any of them, not just CPU/GPU, without
//  inventing a second key-prefix abstraction.
//

import Foundation

public enum Sensor: String, Codable, Equatable, Hashable, CaseIterable {
    case cpu
    case gpu
    case ram
    case ssd
    case ambient

    /// "CPU" / "GPU" / ... — shared by the CLI's `profile show`, the menu bar's
    /// TEMPERATURES rows, and the Custom Curve editor so the label can't drift
    /// between them.
    public var displayName: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .ram: return "RAM"
        case .ssd: return "SSD"
        case .ambient: return "Ambient"
        }
    }

    /// SMC key prefixes for this category — identical to the groupings the menu bar's
    /// TEMPERATURES rows have always used. Internal: callers read a sensor's
    /// temperature via `temperature(in:)`, never these prefixes directly.
    var prefixes: [String] {
        switch self {
        case .cpu: return ["TC", "Tp"]
        case .gpu: return ["TG", "Tg"]
        case .ram: return ["TR", "Tm", "TM"]
        case .ssd: return ["TH"]
        case .ambient: return ["TA"]
        }
    }

    /// This sensor's peak reading in a status snapshot, or nil if none of its keys
    /// are present — e.g. a GPU-less Mac, or a transient read failure.
    public func temperature(in status: ThermalStatus) -> Float? {
        let values = status.temperatures.filter { key, _ in prefixes.contains { key.hasPrefix($0) } }.values
        return values.isEmpty ? nil : values.max()
    }
}
