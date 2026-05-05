import Foundation

public enum ControlEvent: Equatable {
    case idle
    case profileActive(String)
    case safetyTriggered
    case safetyCleared
}

public struct ControlStateMachine {
    public private(set) var state: MonitorState = .idle

    public init(initialState: MonitorState = .idle) {
        self.state = initialState
    }

    @discardableResult
    public mutating func transition(_ event: ControlEvent) -> MonitorState {
        switch event {
        case .idle:
            state = .idle
        case .profileActive(let profileName):
            state = .active(profileName: profileName)
        case .safetyTriggered:
            state = .safetyOverride
        case .safetyCleared:
            if state == .safetyOverride {
                state = .idle
            }
        }
        return state
    }
}
