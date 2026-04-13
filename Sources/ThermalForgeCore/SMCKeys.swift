//
//  SMCKeys.swift
//  ThermalForge
//
//  SMC key constants and data conversion for Apple Silicon.
//

import Foundation

// MARK: - Fan Keys

public enum SMCFanKey {
    /// Number of fans (uint8)
    public static let count = "FNum"
    /// Force test / diagnostic unlock flag (uint8: 0=off, 1=on)
    /// NOTE: Does NOT exist on M5 Max (Mac17,7). Present on M1-M4.
    public static let forceTest = "Ftst"

    // Templated keys — use key(_:fan:) to format with fan index
    /// Actual RPM (read-only, flt)
    public static let actual = "F%dAc"
    /// Target RPM (flt)
    public static let target = "F%dTg"
    /// Minimum RPM recommendation (flt)
    public static let minimum = "F%dMn"
    /// Maximum RPM recommendation (flt)
    public static let maximum = "F%dMx"
    /// Fan mode — lowercase on M5 Max (ui8: 0=auto, 1=manual)
    public static let modeLower = "F%dmd"
    /// Fan mode — uppercase on M1-M4 (ui8: 0=auto, 1=manual, 3=system)
    public static let modeUpper = "F%dMd"
    /// Fan status (ui8, read-only: 3=system-controlled)
    public static let status = "F%dSt"

    public static func key(_ template: String, fan: Int) -> String {
        String(format: template, fan)
    }
}

// MARK: - Data Conversion

/// Convert SMC bytes to Float.
/// Apple Silicon uses IEEE 754 little-endian (4 bytes).
public func smcBytesToFloat(_ bytes: [UInt8], size: UInt32) -> Float {
    guard size == 4, bytes.count >= 4 else { return 0 }
    var value: Float = 0
    memcpy(&value, bytes, 4)
    return value
}

/// Convert Float to SMC bytes (IEEE 754 little-endian, 4 bytes).
public func floatToSMCBytes(_ value: Float) -> [UInt8] {
    var v = value
    return withUnsafeBytes(of: &v) { Array($0) }
}

/// Convert ioft (IOKit fixed-point) bytes to Float.
/// Format: little-endian UInt32, 16.16 fixed-point (upper 16 = integer, lower 16 = fraction).
/// First 4 of 8 bytes used; last 4 are metadata/padding.
public func ioftBytesToFloat(_ bytes: [UInt8]) -> Float {
    guard bytes.count >= 4 else { return 0 }
    var raw: UInt32 = 0
    memcpy(&raw, bytes, 4)
    let integer = Float(raw >> 16)
    let fraction = Float(raw & 0xFFFF) / 65536.0
    return integer + fraction
}

/// Convert fpe2 bytes (14.2 big-endian fixed-point) to Float.
/// Intel Macs use fpe2 for fan RPM keys (F%dAc, F%dTg, F%dMn, F%dMx).
/// Encoding: big-endian UInt16, divide by 4.0 (2 fractional bits).
public func fpe2BytesToFloat(_ bytes: [UInt8], size: UInt32) -> Float {
    guard size == 2, bytes.count >= 2 else { return 0 }
    let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
    return Float(raw) / 4.0
}

/// Convert Float to fpe2 bytes (14.2 big-endian fixed-point).
/// Used when writing fan RPM targets on Intel Macs.
public func floatToFpe2Bytes(_ value: Float) -> [UInt8] {
    let clamped = min(max(value * 4.0, 0), 65535)
    let raw = UInt16(clamped)
    return [UInt8(raw >> 8), UInt8(raw & 0xFF)]
}

/// Convert sp78 bytes (signed 7.8 big-endian fixed-point) to Float.
/// Intel Macs use sp78 for temperature keys.
/// Encoding: signed Int16 big-endian, divide by 256.0 (8 fractional bits).
public func sp78BytesToFloat(_ bytes: [UInt8], size: UInt32) -> Float {
    guard size == 2, bytes.count >= 2 else { return 0 }
    let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
    return Float(raw) / 256.0
}

// MARK: - Architecture Detection

/// Detect CPU architecture at runtime.
/// Used for logging/diagnostics — NOT for data format dispatch.
/// Data format dispatch uses getKeyInfo() type strings instead (more robust).
public enum MachineArchitecture {
    case applesilicon
    case intel

    public static var current: MachineArchitecture {
        var size = 0
        sysctlbyname("hw.optional.arm64", nil, &size, nil, 0)
        var arm64: Int32 = 0
        sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0)
        return arm64 == 1 ? .applesilicon : .intel
    }
}
