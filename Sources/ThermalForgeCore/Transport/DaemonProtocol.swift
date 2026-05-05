import Foundation

public struct DaemonRequest: Codable, Equatable {
    public var version: Int
    public var requestID: String
    public var command: String
    public var rpm: Int?
    public var rule: ThermalRule?
    public var ruleID: String?

    public init(
        version: Int = 1,
        requestID: String = UUID().uuidString,
        command: String,
        rpm: Int? = nil,
        rule: ThermalRule? = nil,
        ruleID: String? = nil
    ) {
        self.version = version
        self.requestID = requestID
        self.command = command
        self.rpm = rpm
        self.rule = rule
        self.ruleID = ruleID
    }
}

public struct DaemonErrorPayload: Codable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct DaemonResponse: Codable, Equatable {
    public var version: Int
    public var requestID: String
    public var ok: Bool
    public var message: String?
    public var status: ThermalStatus?
    public var rules: [ThermalRule]?
    public var error: DaemonErrorPayload?

    public init(
        version: Int = 1,
        requestID: String,
        ok: Bool,
        message: String? = nil,
        status: ThermalStatus? = nil,
        rules: [ThermalRule]? = nil,
        error: DaemonErrorPayload? = nil
    ) {
        self.version = version
        self.requestID = requestID
        self.ok = ok
        self.message = message
        self.status = status
        self.rules = rules
        self.error = error
    }
}
