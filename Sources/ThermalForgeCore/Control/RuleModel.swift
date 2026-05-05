import Foundation

public enum ThermalMetric: String, Codable, CaseIterable {
    case maxTemp
    case cpuTemp
    case gpuTemp
}

public enum RuleComparator: String, Codable, CaseIterable {
    case greaterThan = ">"
    case greaterThanOrEqual = ">="
    case lessThan = "<"
    case lessThanOrEqual = "<="

    public func evaluate(lhs: Float, rhs: Float) -> Bool {
        switch self {
        case .greaterThan: return lhs > rhs
        case .greaterThanOrEqual: return lhs >= rhs
        case .lessThan: return lhs < rhs
        case .lessThanOrEqual: return lhs <= rhs
        }
    }
}

public enum ThermalRuleAction: Codable, Equatable {
    case setMax
    case setRPM(Int)
    case resetAuto
    case selectProfile(String)

    private enum CodingKeys: String, CodingKey {
        case type
        case rpm
        case profileID
    }

    private enum ActionType: String, Codable {
        case setMax
        case setRPM
        case resetAuto
        case selectProfile
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(ActionType.self, forKey: .type)
        switch type {
        case .setMax:
            self = .setMax
        case .setRPM:
            self = .setRPM(try c.decode(Int.self, forKey: .rpm))
        case .resetAuto:
            self = .resetAuto
        case .selectProfile:
            self = .selectProfile(try c.decode(String.self, forKey: .profileID))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .setMax:
            try c.encode(ActionType.setMax, forKey: .type)
        case .setRPM(let rpm):
            try c.encode(ActionType.setRPM, forKey: .type)
            try c.encode(rpm, forKey: .rpm)
        case .resetAuto:
            try c.encode(ActionType.resetAuto, forKey: .type)
        case .selectProfile(let profileID):
            try c.encode(ActionType.selectProfile, forKey: .type)
            try c.encode(profileID, forKey: .profileID)
        }
    }
}

public struct ThermalRuleCondition: Codable, Equatable {
    public let metric: ThermalMetric
    public let comparator: RuleComparator
    public let valueCelsius: Float

    public init(metric: ThermalMetric, comparator: RuleComparator, valueCelsius: Float) {
        self.metric = metric
        self.comparator = comparator
        self.valueCelsius = valueCelsius
    }
}

public struct ThermalRule: Codable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var enabled: Bool
    /// Higher number means higher priority.
    public var priority: Int
    public var condition: ThermalRuleCondition
    public var action: ThermalRuleAction
    /// Optional latch release threshold. If set, rule remains active until maxTemp drops below this value.
    public var untilTempBelowC: Float?

    public init(
        id: String = UUID().uuidString,
        name: String,
        enabled: Bool = true,
        priority: Int = 100,
        condition: ThermalRuleCondition,
        action: ThermalRuleAction,
        untilTempBelowC: Float? = nil
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.priority = priority
        self.condition = condition
        self.action = action
        self.untilTempBelowC = untilTempBelowC
    }
}
