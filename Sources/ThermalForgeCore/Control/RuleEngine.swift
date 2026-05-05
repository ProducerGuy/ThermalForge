import Foundation

public final class RuleEngine {
    public var isEnabled: Bool
    private var rules: [ThermalRule]
    private var latchedRuleID: String?

    public init(rules: [ThermalRule] = [], isEnabled: Bool = true) {
        self.rules = rules
        self.isEnabled = isEnabled
    }

    public func setRules(_ rules: [ThermalRule]) {
        self.rules = rules
        if let latchedRuleID,
           !rules.contains(where: { $0.id == latchedRuleID && $0.enabled })
        {
            self.latchedRuleID = nil
        }
    }

    public func allRules() -> [ThermalRule] {
        rules.sorted { lhs, rhs in
            if lhs.priority == rhs.priority {
                return lhs.name < rhs.name
            }
            return lhs.priority > rhs.priority
        }
    }

    public func evaluate(context: RuleEvaluationContext) -> RuleDecision? {
        guard isEnabled else {
            latchedRuleID = nil
            return nil
        }

        if let latched = resolveLatchedRule(context: context) {
            return latched
        }

        let sorted = allRules().filter { $0.enabled }
        for rule in sorted where matches(rule: rule, context: context) {
            if rule.untilTempBelowC != nil {
                latchedRuleID = rule.id
            }
            return makeDecision(rule: rule)
        }
        return nil
    }

    private func resolveLatchedRule(context: RuleEvaluationContext) -> RuleDecision? {
        guard let latchedRuleID,
              let rule = rules.first(where: { $0.id == latchedRuleID && $0.enabled })
        else {
            self.latchedRuleID = nil
            return nil
        }

        if let until = rule.untilTempBelowC {
            if context.maxTemp > until {
                return makeDecision(rule: rule)
            }
            self.latchedRuleID = nil
            return nil
        }

        self.latchedRuleID = nil
        return nil
    }

    private func matches(rule: ThermalRule, context: RuleEvaluationContext) -> Bool {
        let current: Float
        switch rule.condition.metric {
        case .maxTemp:
            current = context.maxTemp
        case .cpuTemp:
            current = context.cpuTemp
        case .gpuTemp:
            current = context.gpuTemp
        }
        return rule.condition.comparator.evaluate(lhs: current, rhs: rule.condition.valueCelsius)
    }

    private func makeDecision(rule: ThermalRule) -> RuleDecision {
        let command: FanCommand?
        let profileID: String?

        switch rule.action {
        case .setMax:
            command = .setMax
            profileID = nil
        case .setRPM(let rpm):
            command = .setRPM(Float(rpm))
            profileID = nil
        case .resetAuto:
            command = .resetAuto
            profileID = nil
        case .selectProfile(let id):
            command = nil
            profileID = id
        }

        return RuleDecision(
            command: command,
            profileID: profileID,
            sourceRuleID: rule.id,
            sourceRuleName: rule.name
        )
    }
}
