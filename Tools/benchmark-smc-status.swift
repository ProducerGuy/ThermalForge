// Read-only benchmark: no fan writes or thermal workload.
// Build: swift build -c release --target ThermalForgeCore
// swiftc -O -I .build/release/Modules Tools/benchmark-smc-status.swift \
//   .build/release/ThermalForgeCore.build/*.o -framework Metal -framework IOKit \
//   -o /tmp/thermalforge-status-benchmark
// Run without caching, then with caching: /tmp/thermalforge-status-benchmark [--inventory]
import Foundation
import ThermalForgeCore
let initializationStart = ProcessInfo.processInfo.systemUptime
let control = try FanControl()
let enabled = CommandLine.arguments.contains("--inventory")
if enabled { control.enableKeyInventoryCaching() }
let initializationMS = (ProcessInfo.processInfo.systemUptime - initializationStart) * 1000
var readings: [Double] = []
var sensorKeys: [String] = []
var firstStatusMS: Double = 0
for iteration in 0..<205 {
    let start = ProcessInfo.processInfo.systemUptime
    let status = try control.status()
    let elapsed = ProcessInfo.processInfo.systemUptime - start
    if iteration == 0 { firstStatusMS = elapsed * 1000 }
    if iteration >= 5 { readings.append(elapsed) }
    sensorKeys = status.temperatures.keys.sorted()
}
let ordered = readings.sorted()
let result: [String: Any] = ["inventory_enabled": enabled, "initialization_ms": initializationMS, "first_status_ms": firstStatusMS, "reads": readings.count,
    "mean_ms": readings.reduce(0,+) / Double(readings.count) * 1000,
    "median_ms": ordered[ordered.count / 2] * 1000,
    "p95_ms": ordered[Int(Double(ordered.count - 1) * 0.95)] * 1000,
    "sensor_keys": sensorKeys]
print(String(data: try JSONSerialization.data(withJSONObject: result, options: .sortedKeys), encoding: .utf8)!)
