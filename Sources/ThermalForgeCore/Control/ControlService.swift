import Foundation

public struct RuleEvaluationContext: Equatable {
    public let cpuTemp: Float
    public let gpuTemp: Float
    public let maxTemp: Float
    public let profileID: String

    public init(cpuTemp: Float, gpuTemp: Float, maxTemp: Float, profileID: String) {
        self.cpuTemp = cpuTemp
        self.gpuTemp = gpuTemp
        self.maxTemp = maxTemp
        self.profileID = profileID
    }
}

public struct RuleDecision: Equatable {
    public let command: FanCommand?
    public let profileID: String?
    public let sourceRuleID: String
    public let sourceRuleName: String

    public init(command: FanCommand?, profileID: String?, sourceRuleID: String, sourceRuleName: String) {
        self.command = command
        self.profileID = profileID
        self.sourceRuleID = sourceRuleID
        self.sourceRuleName = sourceRuleName
    }
}

public final class ControlService {
    private var stateMachine = ControlStateMachine()
    public private(set) var ruleEngine: RuleEngine

    public init(ruleEngine: RuleEngine = RuleEngine()) {
        self.ruleEngine = ruleEngine
    }

    public func replaceRules(_ rules: [ThermalRule], enabled: Bool) {
        ruleEngine.setRules(rules)
        ruleEngine.isEnabled = enabled
    }

    public func evaluateRules(context: RuleEvaluationContext) -> RuleDecision? {
        ruleEngine.evaluate(context: context)
    }

    @discardableResult
    public func transition(_ event: ControlEvent) -> MonitorState {
        stateMachine.transition(event)
    }

    public func currentState() -> MonitorState {
        stateMachine.state
    }
}
