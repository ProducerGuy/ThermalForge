# Architecture v2

## Layers

1. Hardware
- `FanControl` for SMC reads/writes
- `FanController` / `SensorProvider` protocols for testability

2. Control
- `ThermalMonitor` runtime loop (100ms control cadence)
- `ControlService` and `ControlStateMachine`
- `RuleEngine` and persistent rules

3. Transport
- `DaemonRequest` / `DaemonResponse` typed protocol
- `DaemonCodec` JSON serialization
- backward-compatible legacy text command fallback

4. Observability
- `TFLogger` rotating text logs
- `ThermalEvent` JSONL event stream
- `ThermalLogger` research session export

## Runtime Flow

- App/CLI issues command -> daemon socket
- Daemon authorizes peer UID -> executes command
- App monitor polls sensors -> applies safety/profile/rules
- Rule evaluation happens after safety override check and before profile curve logic

## Safety Ordering

1. Hard safety override (95°C)
2. Rule engine decisions
3. Profile curve logic
4. Idle/hysteresis behavior
