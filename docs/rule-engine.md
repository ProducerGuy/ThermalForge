# Rule Engine

## Model

A rule has:
- `condition` (`metric`, comparator, threshold)
- `action` (`setMax`, `setRPM`, `resetAuto`, `selectProfile`)
- `priority` (higher wins)
- `enabled`
- optional latch release (`untilTempBelowC`)

## Evaluation

1. Disabled engine -> no rule applies.
2. Active latched rule executes until release threshold clears.
3. Otherwise, rules are sorted by priority and first matching enabled rule wins.

## Example

- Condition: `maxTemp >= 55`
- Action: `setMax`
- Latch: until `maxTemp <= 65`

CLI:

```bash
thermalforge rules add --trigger 55 --until 65 --max
```

## Storage

Rules are persisted at:

`~/Library/Application Support/ThermalForge/rules.json`
