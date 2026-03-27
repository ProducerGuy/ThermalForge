//
//  Calibration.swift
//  ThermalForge
//
//  Machine-specific thermal calibration data for the Smart profile.
//

import Foundation

// MARK: - Data Model

public struct CalibrationData: Codable {
    public let machine: String
    public let fans: Int
    public let maxRPM: Int
    public let minRPM: Int
    public let calibratedAt: String
    public let measurements: [Measurement]

    public init(machine: String, fans: Int, maxRPM: Int, minRPM: Int, calibratedAt: String, measurements: [Measurement]) {
        self.machine = machine
        self.fans = fans
        self.maxRPM = maxRPM
        self.minRPM = minRPM
        self.calibratedAt = calibratedAt
        self.measurements = measurements
    }

    public struct Measurement: Codable {
        /// Fan speed as fraction of max RPM (0.0–1.0)
        public let rpmPercent: Float
        /// Cooling rate in °C/sec (negative = cooling)
        public let coolingRate: Float
        /// Heating rate under load in °C/sec (positive = heating)
        public let heatingRate: Float
        /// Temperature where heating and cooling reach equilibrium under load
        public let steadyState: Float

        public init(rpmPercent: Float, coolingRate: Float, heatingRate: Float, steadyState: Float) {
            self.rpmPercent = rpmPercent
            self.coolingRate = coolingRate
            self.heatingRate = heatingRate
            self.steadyState = steadyState
        }
    }

    /// Interpolate the RPM percentage needed to hold a target temperature under load.
    /// Returns nil if calibration data can't answer the question.
    public func rpmPercentForTarget(_ targetTemp: Float) -> Float? {
        guard measurements.count >= 2 else { return nil }

        // Find the two measurements that bracket the target steady-state
        let sorted = measurements.sorted { $0.steadyState > $1.steadyState }

        // Target is hotter than our lowest RPM steady state — even minimum fans keep it cooler
        if targetTemp >= sorted.first!.steadyState {
            return sorted.first!.rpmPercent
        }
        // Target is cooler than our highest RPM steady state — need max fans
        if targetTemp <= sorted.last!.steadyState {
            return sorted.last!.rpmPercent
        }

        // Interpolate between the two bracketing measurements
        for i in 0..<(sorted.count - 1) {
            let high = sorted[i]
            let low = sorted[i + 1]
            if targetTemp <= high.steadyState && targetTemp >= low.steadyState {
                let t = (high.steadyState - targetTemp) / (high.steadyState - low.steadyState)
                return high.rpmPercent + t * (low.rpmPercent - high.rpmPercent)
            }
        }

        return nil
    }

    /// Get the cooling rate at a given RPM percentage (interpolated)
    public func coolingRateAt(rpmPercent: Float) -> Float {
        guard measurements.count >= 2 else { return -1.0 }
        let sorted = measurements.sorted { $0.rpmPercent < $1.rpmPercent }

        if rpmPercent <= sorted.first!.rpmPercent { return sorted.first!.coolingRate }
        if rpmPercent >= sorted.last!.rpmPercent { return sorted.last!.coolingRate }

        for i in 0..<(sorted.count - 1) {
            let low = sorted[i]
            let high = sorted[i + 1]
            if rpmPercent >= low.rpmPercent && rpmPercent <= high.rpmPercent {
                let t = (rpmPercent - low.rpmPercent) / (high.rpmPercent - low.rpmPercent)
                return low.coolingRate + t * (high.coolingRate - low.coolingRate)
            }
        }
        return sorted.last!.coolingRate
    }
}

// MARK: - Persistence

extension CalibrationData {
    public static var filePath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ThermalForge/calibration.json")
    }

    public func save() throws {
        let dir = Self.filePath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: Self.filePath)
    }

    public static func load() -> CalibrationData? {
        guard let data = try? Data(contentsOf: filePath),
              let calibration = try? JSONDecoder().decode(CalibrationData.self, from: data)
        else { return nil }
        return calibration
    }

    public static var exists: Bool {
        FileManager.default.fileExists(atPath: filePath.path)
    }
}

// MARK: - Calibration Mode

/// Calibration modes based on thermal engineering research.
///
/// Apple Silicon MacBooks reach ~95% of thermal steady state in 4.5-6 minutes
/// under sustained load (thermal time constant ~90-120s, measured across M1-M5
/// by Notebookcheck, Max Tech). Mac Studio takes 5-7 minutes due to 2-3x
/// thermal mass. Cooling time constant is ~60-90s at max fan, 3-5 min at idle.
///
/// Sources:
/// - Notebookcheck MacBook Pro M1 Max, M2 Max, M3 Max, M4 Max stress tests
/// - Max Tech sustained performance testing methodology
/// - Thermal time constant = thermal mass × thermal resistance
///   ~20-50 J/K × 0.3-0.8 K/W = 60-180s for laptop heatsink assemblies
/// - 3 time constants = 95% of steady state, 5 time constants = 99.3%
public enum CalibrationMode: String, CaseIterable {
    /// ~10 minutes. 2 min heat + 30s cool per level.
    /// Reaches ~75% of steady state. Good baseline data.
    case quick

    /// ~28 minutes. 5 min heat + 2 min cool per level.
    /// Reaches ~95% of steady state (3 thermal time constants).
    /// Reliable for all Apple Silicon Macs including Mac Studio.
    case standard

    /// Varies (est. 35-50 min). Runs until temperature stabilizes.
    /// Exits each phase when rate of change <0.5°C over 60 seconds.
    /// Ceiling of 10 min heat + 5 min cool per level (5 time constants = 99.3%).
    /// Produces the most accurate data and logs time-to-steady-state.
    case thorough

    public var description: String {
        switch self {
        case .quick: return "Quick (~10 min)"
        case .standard: return "Standard (~28 min)"
        case .thorough: return "Thorough (until stable, ~35-50 min)"
        }
    }

    /// Heat phase duration in seconds per level
    public var heatSeconds: Int {
        switch self {
        case .quick: return 120       // 2 min
        case .standard: return 300    // 5 min
        case .thorough: return 600    // 10 min max, exits early on steady state
        }
    }

    /// Cool phase duration in seconds per level
    public var coolSeconds: Int {
        switch self {
        case .quick: return 30
        case .standard: return 120    // 2 min
        case .thorough: return 300    // 5 min max, exits early on steady state
        }
    }

    /// Whether to use steady-state detection to exit phases early
    public var usesSteadyStateDetection: Bool {
        self == .thorough
    }
}

// MARK: - Calibration Runner

public final class CalibrationRunner {
    private let fanControl: FanControl
    private let mode: CalibrationMode
    private var stressThreads: [Thread] = []
    private var stressRunning = false
    private let isoFormatter = ISO8601DateFormatter()

    public var onProgress: ((String) -> Void)?

    /// Path to the CSV log generated during calibration
    public private(set) var logPath: URL?

    // CSV log handle — written to in real time during calibration
    private var csvHandle: FileHandle?

    public init(fanControl: FanControl, mode: CalibrationMode = .standard) {
        self.fanControl = fanControl
        self.mode = mode
    }

    /// Run full calibration. Blocks until complete.
    public func run() throws -> CalibrationData {
        let fanCount = try fanControl.fanCount()
        let fan0 = try fanControl.fanInfo(0)
        let maxRPM = fan0.maxRPM
        let minRPM = fan0.minRPM

        // Machine info
        var sysSize = 0
        sysctlbyname("hw.model", nil, &sysSize, nil, 0)
        var modelBuf = [CChar](repeating: 0, count: Swift.max(sysSize, 1))
        sysctlbyname("hw.model", &modelBuf, &sysSize, nil, 0)
        let machine = String(cString: modelBuf)

        log("Mode: \(mode.description)")

        // Set up CSV log
        let logDir = CalibrationData.filePath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let timestamp = isoFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let csvURL = logDir.appendingPathComponent("calibration_\(timestamp).csv")
        FileManager.default.createFile(atPath: csvURL.path, contents: nil)
        csvHandle = try FileHandle(forWritingTo: csvURL)
        logPath = csvURL

        // CSV header
        csvWrite("timestamp,phase,rpm_pct,fan0_rpm,fan1_rpm,peak_cpu_c,peak_gpu_c,stress_active")

        let rpmLevels: [Float] = [0.25, 0.50, 0.75, 1.00]
        var measurements: [CalibrationData.Measurement] = []

        for pct in rpmLevels {
            let targetRPM = maxRPM * pct
            let label = "\(Int(pct * 100))%"

            // Phase A: Heat — stress CPU at fixed fan speed
            log("[\(label)] Heating with fans at \(Int(targetRPM)) RPM...")
            try fanControl.setAllFans(rpm: targetRPM)
            startStress()

            let heatingReadings = samplePhase(
                maxSeconds: mode.heatSeconds,
                phase: "heating", rpmPct: pct, stressActive: true
            )
            let heatingRate = rateFromReadings(heatingReadings)
            let steadyState = heatingReadings.last ?? 0

            log("[\(label)] Heating rate: \(String(format: "%.2f", heatingRate))°C/s, temp: \(String(format: "%.1f", steadyState))°C (\(heatingReadings.count * 2)s)")

            // Phase B: Cool — stop stress, keep fans at same speed
            stopStress()
            log("[\(label)] Cooling at \(Int(targetRPM)) RPM...")

            let coolingReadings = samplePhase(
                maxSeconds: mode.coolSeconds,
                phase: "cooling", rpmPct: pct, stressActive: false
            )
            let coolingRate = rateFromReadings(coolingReadings)

            log("[\(label)] Cooling rate: \(String(format: "%.2f", coolingRate))°C/s (\(coolingReadings.count * 2)s)")

            measurements.append(CalibrationData.Measurement(
                rpmPercent: pct,
                coolingRate: coolingRate,
                heatingRate: heatingRate,
                steadyState: steadyState
            ))

            // Brief pause between levels
            Thread.sleep(forTimeInterval: 5)
        }

        // Reset fans
        try fanControl.resetAuto()
        stopStress()
        csvHandle?.closeFile()
        csvHandle = nil

        return CalibrationData(
            machine: machine,
            fans: fanCount,
            maxRPM: Int(maxRPM),
            minRPM: Int(minRPM),
            calibratedAt: isoFormatter.string(from: Date()),
            measurements: measurements
        )
    }

    // MARK: - Stress

    private func startStress() {
        guard !stressRunning else { return }
        stressRunning = true

        let coreCount = ProcessInfo.processInfo.activeProcessorCount
        for _ in 0..<coreCount {
            let thread = Thread {
                while self.stressRunning {
                    var x: Double = 1.0
                    for i in 1...10000 {
                        x = sin(x) * cos(Double(i))
                    }
                    _ = x
                }
            }
            thread.qualityOfService = .userInteractive
            thread.start()
            stressThreads.append(thread)
        }
    }

    private func stopStress() {
        stressRunning = false
        stressThreads.removeAll()
        Thread.sleep(forTimeInterval: 1)
    }

    // MARK: - Sampling

    /// Sample for up to maxSeconds. In Thorough mode, exits early if steady state detected.
    /// Steady state: temperature change <0.5°C over the last 60 seconds (30 readings).
    private func samplePhase(maxSeconds: Int, phase: String, rpmPct: Float, stressActive: Bool) -> [Float] {
        var readings: [Float] = []
        let maxTicks = maxSeconds / 2

        for tick in 0..<maxTicks {
            if let status = try? fanControl.status() {
                let cpuTemp = status.temperatures
                    .filter { k, _ in k.hasPrefix("TC") || k.hasPrefix("Tp") }
                    .values.max() ?? 0
                let gpuTemp = status.temperatures
                    .filter { k, _ in k.hasPrefix("TG") || k.hasPrefix("Tg") }
                    .values.max() ?? 0
                let peakTemp = Swift.max(cpuTemp, gpuTemp)
                readings.append(peakTemp)

                // Write CSV row
                let fan0 = status.fans.first.map { $0.actualRPM } ?? 0
                let fan1 = status.fans.count > 1 ? status.fans[1].actualRPM : 0
                let ts = isoFormatter.string(from: Date())
                csvWrite("\(ts),\(phase),\(String(format: "%.2f", rpmPct)),\(fan0),\(fan1),\(String(format: "%.1f", cpuTemp)),\(String(format: "%.1f", gpuTemp)),\(stressActive)")

                // Steady-state detection for Thorough mode
                // Check after at least 60 seconds (30 readings at 2s intervals)
                if mode.usesSteadyStateDetection && readings.count >= 30 {
                    let recent = readings.suffix(30)
                    let recentMin = recent.min() ?? 0
                    let recentMax = recent.max() ?? 0
                    if recentMax - recentMin < 0.5 {
                        log("  Steady state detected at \(tick * 2)s (\(String(format: "%.1f", peakTemp))°C)")
                        break
                    }
                }
            }
            Thread.sleep(forTimeInterval: 2)
        }
        return readings
    }

    private func rateFromReadings(_ readings: [Float]) -> Float {
        guard readings.count >= 2 else { return 0 }
        let first = readings.first!
        let last = readings.last!
        let seconds = Float(readings.count - 1) * 2.0
        return (last - first) / seconds
    }

    // MARK: - Logging

    private func csvWrite(_ line: String) {
        if let data = (line + "\n").data(using: .utf8) {
            csvHandle?.write(data)
        }
    }

    private func log(_ message: String) {
        onProgress?(message)
    }
}
