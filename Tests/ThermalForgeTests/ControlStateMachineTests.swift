import Testing

@testable import ThermalForgeCore

@Suite("Control State Machine")
struct ControlStateMachineTests {
    @Test("Transitions to safety and clears")
    func safetyTransitions() {
        var machine = ControlStateMachine()
        #expect(machine.state == .idle)

        _ = machine.transition(.profileActive("Balanced"))
        #expect(machine.state == .active(profileName: "Balanced"))

        _ = machine.transition(.safetyTriggered)
        #expect(machine.state == .safetyOverride)

        _ = machine.transition(.safetyCleared)
        #expect(machine.state == .idle)
    }

    @Test("Idle event always resets state")
    func idleReset() {
        var machine = ControlStateMachine(initialState: .active(profileName: "Performance"))
        _ = machine.transition(.idle)
        #expect(machine.state == .idle)
    }
}
