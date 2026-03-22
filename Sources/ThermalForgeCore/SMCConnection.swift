//
//  SMCConnection.swift
//  ThermalForge
//
//  Low-level interface to Apple's System Management Controller via IOKit.
//  Adapted from agoodkind/macos-smc-fan (MIT).
//

import Foundation
import IOKit

// MARK: - SMC Constants

/// SMC command identifiers written to data8 field
enum SMCCommand: UInt8 {
    case readBytes = 5
    case writeBytes = 6
    case getKeyFromIndex = 8
    case readKeyInfo = 9
}

/// IOConnectCallStructMethod selector for AppleSMC
private let kSMCHandleIndex: UInt32 = 2

// MARK: - SMC Data Structures

/// 80-byte structure matching the AppleSMC kernel interface.
/// Layout must exactly match what IOConnectCallStructMethod expects.
struct SMCParamStruct {
    struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct PLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = Version()
    var pLimitData = PLimitData()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    ) = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
}

// MARK: - SMC Connection

/// Direct IOKit interface to the System Management Controller.
/// Requires elevated privileges (sudo) for write operations.
public final class SMCConnection {

    private let connection: io_connect_t

    public init?() {
        var iterator: io_iterator_t = 0
        defer { IOObjectRelease(iterator) }

        guard
            IOServiceGetMatchingServices(
                kIOMainPortDefault,
                IOServiceMatching("AppleSMC"),
                &iterator
            ) == kIOReturnSuccess
        else { return nil }

        let service = IOIteratorNext(iterator)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess else {
            return nil
        }
        self.connection = conn
    }

    deinit {
        IOServiceClose(connection)
    }

    // MARK: - Public API

    /// Read raw bytes from an SMC key
    public func readKey(_ key: String) -> (success: Bool, bytes: [UInt8], size: UInt32) {
        var input = SMCParamStruct()
        var output = SMCParamStruct()

        // Get key info (data size)
        input.key = fourCharCode(key)
        input.data8 = SMCCommand.readKeyInfo.rawValue
        guard callSMC(&input, &output) == kIOReturnSuccess else {
            return (false, [], 0)
        }

        let dataSize = output.keyInfo.dataSize
        guard dataSize > 0 else { return (false, [], 0) }

        // Read value
        input.keyInfo.dataSize = dataSize
        input.data8 = SMCCommand.readBytes.rawValue
        guard callSMC(&input, &output) == kIOReturnSuccess else {
            return (false, [], 0)
        }

        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(dataSize))) }
        return (true, bytes, dataSize)
    }

    /// Write raw bytes to an SMC key
    public func writeKey(_ key: String, bytes: [UInt8]) -> Bool {
        var input = SMCParamStruct()
        var output = SMCParamStruct()

        // Get key info first
        input.key = fourCharCode(key)
        input.data8 = SMCCommand.readKeyInfo.rawValue
        guard callSMC(&input, &output) == kIOReturnSuccess else {
            return false
        }

        // Write value
        input.data8 = SMCCommand.writeBytes.rawValue
        input.keyInfo.dataSize = output.keyInfo.dataSize
        input.bytes = arrayToTuple(bytes)

        guard callSMC(&input, &output) == kIOReturnSuccess else {
            return false
        }

        // IOKit may return success even when SMC firmware rejects the write
        return output.result == 0
    }

    /// Get total number of SMC keys
    public func getKeyCount() -> UInt32 {
        let result = readKey("#KEY")
        guard result.success, result.bytes.count >= 4 else { return 0 }
        // #KEY returns big-endian uint32
        return UInt32(result.bytes[0]) << 24
            | UInt32(result.bytes[1]) << 16
            | UInt32(result.bytes[2]) << 8
            | UInt32(result.bytes[3])
    }

    /// Get the key name at a given index (for enumeration)
    public func getKeyAtIndex(_ index: UInt32) -> String? {
        var input = SMCParamStruct()
        var output = SMCParamStruct()

        input.data8 = SMCCommand.getKeyFromIndex.rawValue
        input.data32 = index

        guard callSMC(&input, &output) == kIOReturnSuccess else {
            return nil
        }

        return fourCharString(output.key)
    }

    /// Read key info (data size and type code)
    public func getKeyInfo(_ key: String) -> (size: UInt32, type: String)? {
        var input = SMCParamStruct()
        var output = SMCParamStruct()

        input.key = fourCharCode(key)
        input.data8 = SMCCommand.readKeyInfo.rawValue

        guard callSMC(&input, &output) == kIOReturnSuccess else {
            return nil
        }

        return (output.keyInfo.dataSize, fourCharString(output.keyInfo.dataType))
    }

    // MARK: - Private

    private func callSMC(_ input: inout SMCParamStruct, _ output: inout SMCParamStruct) -> kern_return_t {
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        return IOConnectCallStructMethod(
            connection,
            kSMCHandleIndex,
            &input,
            MemoryLayout<SMCParamStruct>.stride,
            &output,
            &outputSize
        )
    }

    private func fourCharCode(_ key: String) -> UInt32 {
        precondition(key.utf8.count == 4, "SMC keys must be exactly 4 characters")
        return key.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func fourCharString(_ code: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    private func arrayToTuple(_ array: [UInt8]) -> SMCParamStruct.Bytes {
        var padded = array + Array(repeating: UInt8(0), count: max(0, 32 - array.count))
        if padded.count > 32 { padded = Array(padded.prefix(32)) }
        return (
            padded[0], padded[1], padded[2], padded[3],
            padded[4], padded[5], padded[6], padded[7],
            padded[8], padded[9], padded[10], padded[11],
            padded[12], padded[13], padded[14], padded[15],
            padded[16], padded[17], padded[18], padded[19],
            padded[20], padded[21], padded[22], padded[23],
            padded[24], padded[25], padded[26], padded[27],
            padded[28], padded[29], padded[30], padded[31]
        )
    }
}

// Type alias for the 32-byte tuple used in SMCParamStruct
extension SMCParamStruct {
    typealias Bytes = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )
}
