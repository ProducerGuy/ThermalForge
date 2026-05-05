import Foundation

public enum ThermalEventType: String, Codable {
    case safetyOverrideTriggered
    case safetyOverrideCleared
    case ruleTriggered
    case daemonCommandRejected
    case daemonCommandFailed
}

public struct ThermalEvent: Codable {
    public let timestamp: String
    public let type: ThermalEventType
    public let details: String

    public init(type: ThermalEventType, details: String) {
        self.timestamp = ISO8601DateFormatter().string(from: Date())
        self.type = type
        self.details = details
    }
}
