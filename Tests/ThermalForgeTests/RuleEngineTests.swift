import Testing

@testable import ThermalForgeCore

@Suite("Rule Engine")
struct RuleEngineTests {
    @Test("Highest priority matching rule wins")
    func highestPriorityWins() {
        let low = ThermalRule(
            id: "low",
            name: "low",
            enabled: true,
            priority: 10,
            condition: ThermalRuleCondition(metric: .maxTemp, comparator: .greaterThanOrEqual, valueCelsius: 55),
            action: .setRPM(3000)
        )
        let high = ThermalRule(
            id: "high",
            name: "high",
            enabled: true,
            priority: 100,
            condition: ThermalRuleCondition(metric: .maxTemp, comparator: .greaterThanOrEqual, valueCelsius: 55),
            action: .setMax
        )

        let engine = RuleEngine(rules: [low, high], isEnabled: true)
        let decision = engine.evaluate(context: RuleEvaluationContext(cpuTemp: 56, gpuTemp: 52, maxTemp: 56, profileID: "balanced"))

        #expect(decision != nil)
        #expect(decision?.sourceRuleID == "high")
        #expect(decision?.command == .setMax)
    }

    @Test("Latched rule stays active until release threshold")
    func latchedRule() {
        let rule = ThermalRule(
            id: "latched",
            name: "latched",
            enabled: true,
            priority: 500,
            condition: ThermalRuleCondition(metric: .maxTemp, comparator: .greaterThanOrEqual, valueCelsius: 70),
            action: .setMax,
            untilTempBelowC: 65
        )

        let engine = RuleEngine(rules: [rule], isEnabled: true)

        let hot = engine.evaluate(context: RuleEvaluationContext(cpuTemp: 72, gpuTemp: 70, maxTemp: 72, profileID: "balanced"))
        #expect(hot?.command == .setMax)

        let coolingButStillLatched = engine.evaluate(context: RuleEvaluationContext(cpuTemp: 67, gpuTemp: 64, maxTemp: 67, profileID: "balanced"))
        #expect(coolingButStillLatched?.command == .setMax)

        let released = engine.evaluate(context: RuleEvaluationContext(cpuTemp: 64, gpuTemp: 63, maxTemp: 64, profileID: "balanced"))
        #expect(released == nil)
    }

    @Test("Disabled engine returns no decisions")
    func disabledEngine() {
        let rule = ThermalRule(
            id: "disabled",
            name: "disabled",
            enabled: true,
            priority: 100,
            condition: ThermalRuleCondition(metric: .maxTemp, comparator: .greaterThanOrEqual, valueCelsius: 55),
            action: .setMax
        )

        let engine = RuleEngine(rules: [rule], isEnabled: false)
        let decision = engine.evaluate(context: RuleEvaluationContext(cpuTemp: 80, gpuTemp: 75, maxTemp: 80, profileID: "max"))
        #expect(decision == nil)
    }
}
