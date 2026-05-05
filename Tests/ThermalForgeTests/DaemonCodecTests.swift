import Testing

@testable import ThermalForgeCore

@Suite("Daemon Codec")
struct DaemonCodecTests {
    @Test("Request round-trip")
    func requestRoundTrip() throws {
        let rule = ThermalRule(
            id: "rule-1",
            name: "example",
            enabled: true,
            priority: 900,
            condition: ThermalRuleCondition(metric: .maxTemp, comparator: .greaterThanOrEqual, valueCelsius: 55),
            action: .setMax,
            untilTempBelowC: 65
        )
        let original = DaemonRequest(command: "rules.put", rpm: nil, rule: rule, ruleID: nil)
        let encoded = try DaemonCodec.encodeRequest(original)
        let decoded = try DaemonCodec.decodeRequest(encoded)
        #expect(decoded == original)
    }

    @Test("Response round-trip with error")
    func responseRoundTrip() throws {
        let original = DaemonResponse(
            requestID: "abc",
            ok: false,
            message: nil,
            status: nil,
            rules: nil,
            error: DaemonErrorPayload(code: "validation_error", message: "missing rule")
        )
        let encoded = try DaemonCodec.encodeResponse(original)
        let decoded = try DaemonCodec.decodeResponse(encoded)
        #expect(decoded == original)
    }
}
