import Foundation
import IOKit
import Testing
@testable import ThermalForgeCore

@Suite("SMC readback — no hardware and no metadata cache")
struct SMCReadTests {
    @Test("Firmware-rejected metadata or bytes cannot look like automatic mode zero")
    func rejectedReadback() {
        for rejectedCommand in [SMCCommand.readKeyInfo.rawValue, SMCCommand.readBytes.rawValue] {
            let connection = SMCConnection { input, output in
                output.keyInfo.dataSize = 1
                output.result = input.data8 == rejectedCommand ? 1 : 0
                return kIOReturnSuccess
            }
            #expect(!connection.readKey("F0Md").success)
        }
    }

    @Test("Metadata and values are refreshed on every read")
    func freshReads() {
        var metadataReads = 0
        var valueReads = 0
        let connection = SMCConnection { input, output in
            output.result = 0
            if input.data8 == SMCCommand.readKeyInfo.rawValue {
                metadataReads += 1
                output.keyInfo.dataSize = 1
            } else {
                valueReads += 1
                output.bytes.0 = UInt8(valueReads)
            }
            return kIOReturnSuccess
        }
        #expect(connection.readKey("F0Md").bytes == [1])
        #expect(connection.readKey("F0Md").bytes == [2])
        #expect(metadataReads == 2 && valueReads == 2)
    }

    @Test("Invalid metadata sizes do not start a value read")
    func invalidSizes() {
        for size in [UInt32(0), 33] {
            let connection = SMCConnection { input, output in
                #expect(input.data8 == SMCCommand.readKeyInfo.rawValue)
                output.keyInfo.dataSize = size
                return kIOReturnSuccess
            }
            #expect(!connection.readKey("F0Md").success)
        }
    }
}
