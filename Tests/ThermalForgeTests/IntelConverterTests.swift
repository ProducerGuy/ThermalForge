import XCTest
@testable import ThermalForgeCore

final class IntelConverterTests: XCTestCase {

    // MARK: - fpe2 (Fan RPM)

    func testFpe2_2000RPM() {
        // 2000 RPM = 2000 * 4 = 8000 = 0x1F40
        let temp = fpe2BytesToFloat([0x1F, 0x40], size: 2)
        XCTAssertEqual(temp, 2000.0, accuracy: 0.5)
    }

    func testFpe2_zero() {
        let temp = fpe2BytesToFloat([0x00, 0x00], size: 2)
        XCTAssertEqual(temp, 0.0)
    }

    func testFpe2_maxRPM() {
        // 7826 RPM (typical Apple max) = 7826 * 4 = 31304 = 0x7A48
        let temp = fpe2BytesToFloat([0x7A, 0x48], size: 2)
        XCTAssertEqual(temp, 7826.0, accuracy: 0.5)
    }

    func testFpe2_roundTrip() {
        let original: Float = 3456.0
        let encoded = floatToFpe2Bytes(original)
        let decoded = fpe2BytesToFloat(encoded, size: 2)
        XCTAssertEqual(decoded, original, accuracy: 0.5)
    }

    func testFpe2_wrongSize() {
        XCTAssertEqual(fpe2BytesToFloat([0x1F], size: 1), 0.0)
        XCTAssertEqual(fpe2BytesToFloat([], size: 0), 0.0)
    }

    // MARK: - sp78 (Temperature)

    func testSp78_72point5C() {
        // 72.5°C = 72.5 * 256 = 18560 = 0x4880
        let temp = sp78BytesToFloat([0x48, 0x80], size: 2)
        XCTAssertEqual(temp, 72.5, accuracy: 0.1)
    }

    func testSp78_zero() {
        let temp = sp78BytesToFloat([0x00, 0x00], size: 2)
        XCTAssertEqual(temp, 0.0)
    }

    func testSp78_negative() {
        // -10°C = -10 * 256 = -2560 = 0xF600
        let temp = sp78BytesToFloat([0xF6, 0x00], size: 2)
        XCTAssertEqual(temp, -10.0, accuracy: 0.1)
    }

    func testSp78_highTemp() {
        // 95°C = 95 * 256 = 24320 = 0x5F00
        let temp = sp78BytesToFloat([0x5F, 0x00], size: 2)
        XCTAssertEqual(temp, 95.0, accuracy: 0.1)
    }

    func testSp78_wrongSize() {
        XCTAssertEqual(sp78BytesToFloat([0x48], size: 1), 0.0)
        XCTAssertEqual(sp78BytesToFloat([], size: 0), 0.0)
    }

    // MARK: - Existing converters (regression)

    func testFlt_unchanged() {
        var value: Float = 72.5
        let bytes = withUnsafeBytes(of: &value) { Array($0) }
        let result = smcBytesToFloat(bytes, size: 4)
        XCTAssertEqual(result, 72.5, accuracy: 0.01)
    }

    func testFloatToSMCBytes_unchanged() {
        let bytes = floatToSMCBytes(2000.0)
        let result = smcBytesToFloat(bytes, size: 4)
        XCTAssertEqual(result, 2000.0, accuracy: 0.01)
    }

    // MARK: - Architecture Detection

    func testArchitectureDetection() {
        let arch = MachineArchitecture.current
        XCTAssertTrue(arch == .applesilicon || arch == .intel)
    }
}
