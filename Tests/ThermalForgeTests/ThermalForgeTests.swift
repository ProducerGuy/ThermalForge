//
//  ThermalForgeTests.swift
//  ThermalForge
//

import Testing

@testable import ThermalForgeCore

@Suite("Data Conversion")
struct DataConversionTests {

    @Test("Float round-trips through SMC byte encoding")
    func floatRoundTrip() {
        let values: [Float] = [0.0, 1200.0, 2317.0, 3500.5, 5900.0, 7826.0]
        for original in values {
            let bytes = floatToSMCBytes(original)
            #expect(bytes.count == 4)
            let decoded = smcBytesToFloat(bytes, size: 4)
            #expect(decoded == original, "Round-trip failed for \(original)")
        }
    }

    @Test("Zero RPM encodes to all zeros")
    func zeroRPM() {
        let bytes = floatToSMCBytes(0.0)
        #expect(bytes == [0, 0, 0, 0])
    }

    @Test("Undersized byte array returns zero")
    func undersizedBytes() {
        let result = smcBytesToFloat([0x00, 0x00], size: 2)
        #expect(result == 0.0)
    }

    @Test("Wrong size parameter returns zero")
    func wrongSize() {
        let bytes = floatToSMCBytes(1200.0)
        let result = smcBytesToFloat(bytes, size: 2)
        #expect(result == 0.0)
    }

    @Test("ioft 16.16 fixed-point decoding")
    func ioftDecoding() {
        // 31.0 C = 0x001F0000 little-endian = [00, 00, 1f, 00, 00, 00, 00, 00]
        let gpu31 = ioftBytesToFloat([0x00, 0x00, 0x1f, 0x00, 0x00, 0x00, 0x00, 0x00])
        #expect(gpu31 == 31.0)

        // 30.6 C = 0x001E9999 little-endian = [99, 99, 1e, 00, 00, 00, 00, 00]
        let gpu30_6 = ioftBytesToFloat([0x99, 0x99, 0x1e, 0x00, 0x00, 0x00, 0x00, 0x00])
        #expect(abs(gpu30_6 - 30.6) < 0.01, "Expected ~30.6, got \(gpu30_6)")

        // Empty bytes returns zero
        #expect(ioftBytesToFloat([]) == 0.0)
    }
}

@Suite("Fan Key Formatting")
struct FanKeyTests {

    @Test("Fan key templates produce correct key names")
    func keyFormatting() {
        #expect(SMCFanKey.key(SMCFanKey.actual, fan: 0) == "F0Ac")
        #expect(SMCFanKey.key(SMCFanKey.actual, fan: 1) == "F1Ac")
        #expect(SMCFanKey.key(SMCFanKey.target, fan: 0) == "F0Tg")
        #expect(SMCFanKey.key(SMCFanKey.minimum, fan: 0) == "F0Mn")
        #expect(SMCFanKey.key(SMCFanKey.maximum, fan: 0) == "F0Mx")
    }

    @Test("Mode keys for both hardware variants")
    func modeKeys() {
        // M5 Max (lowercase)
        #expect(SMCFanKey.key(SMCFanKey.modeLower, fan: 0) == "F0md")
        #expect(SMCFanKey.key(SMCFanKey.modeLower, fan: 1) == "F1md")
        // M1-M4 (uppercase)
        #expect(SMCFanKey.key(SMCFanKey.modeUpper, fan: 0) == "F0Md")
        #expect(SMCFanKey.key(SMCFanKey.modeUpper, fan: 2) == "F2Md")
    }

    @Test("Static keys are correct")
    func staticKeys() {
        #expect(SMCFanKey.count == "FNum")
        #expect(SMCFanKey.forceTest == "Ftst")
    }
}
