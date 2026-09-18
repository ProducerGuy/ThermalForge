//
//  Sensor.swift
//  ThermalForge
//
//  Which peak temperature a dual-sensor Custom Curve point reads. Reuses the same
//  CPU/GPU key-prefix grouping `ThermalStatus.safetyPeakTemp` and the menu bar
//  already use, rather than inventing a second sensor abstraction.
//

import Foundation

public enum Sensor: String, Codable, Equatable, Hashable, CaseIterable {
    case cpu
    case gpu

    /// "CPU" / "GPU" — shared by the CLI's `profile show` and the menu bar editor so
    /// the label can't drift between them.
    public var displayName: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        }
    }

    var prefixes: [String] {
        switch self {
        case .cpu: return ["TC", "Tp"]
        case .gpu: return ["TG", "Tg"]
        }
    }

    /// This sensor's peak reading in a status snapshot, or nil if none of its keys
    /// are present — e.g. a GPU-less Mac, or a transient read failure.
    public func temperature(in status: ThermalStatus) -> Float? {
        let values = status.temperatures.filter { key, _ in prefixes.contains { key.hasPrefix($0) } }.values
        return values.isEmpty ? nil : values.max()
    }
}
