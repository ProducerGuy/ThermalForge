//
//  Calibration.swift
//  ThermalForge
//
//  Machine-specific thermal calibration data for the Smart profile.
//

import Foundation
import Metal

// MARK: - Data Model

public struct CalibrationData: Codable {
    public let machine: String
    public let fans: Int
    public let maxRPM: Int
    public let minRPM: Int
    public let calibratedAt: String
    public let mode: String?
    public let measurements: [Measurement]

    public init(machine: String, fans: Int, maxRPM: Int, minRPM: Int, calibratedAt: String, mode: String? = nil, measurements: [Measurement]) {
        self.machine = machine
        self.fans = fans
        self.maxRPM = maxRPM
        self.minRPM = minRPM
        self.calibratedAt = calibratedAt
        self.mode = mode
        self.measurements = measurements
    }

    /// Ranking for downgrade prevention: quick=1, standard=2, optimized=3
    public var modeRank: Int {
        switch mode {
        case "quick": return 1
        case "standard": return 2
        case "optimized": return 3
        default: return 0 // legacy data without mode field
        }
    }

    public struct Measurement: Codable {
        /// Target temperature this measurement was taken at
        public let targetTemp: Float
        /// Fan speed (0.0–1.0 of max RPM) that held temp at targetTemp
        public let holdingRPMPercent: Float
        /// How long (seconds) it took to find the holding speed
        public let settleTime: Float?

        public init(targetTemp: Float, holdingRPMPercent: Float, settleTime: Float? = nil) {
            self.targetTemp = targetTemp
            self.holdingRPMPercent = holdingRPMPercent
            self.settleTime = settleTime
        }
    }

    /// Look up the fan speed needed to hold a given temperature.
    /// Interpolates between measured points.
    public func fanPercentForTemp(_ temp: Float) -> Float? {
        guard measurements.count >= 2 else { return nil }
        let sorted = measurements.sorted { $0.targetTemp < $1.targetTemp }

        // Below lowest measured temp — use lowest fan speed
        if temp <= sorted.first!.targetTemp { return sorted.first!.holdingRPMPercent }
        // Above highest measured temp — use highest fan speed
        if temp >= sorted.last!.targetTemp { return sorted.last!.holdingRPMPercent }

        // Interpolate between bracketing measurements
        for i in 0..<(sorted.count - 1) {
            let low = sorted[i]
            let high = sorted[i + 1]
            if temp >= low.targetTemp && temp <= high.targetTemp {
                let t = (temp - low.targetTemp) / (high.targetTemp - low.targetTemp)
                return low.holdingRPMPercent + t * (high.holdingRPMPercent - low.holdingRPMPercent)
            }
        }
        return sorted.last!.holdingRPMPercent
    }

    /// Validate that calibration data is physically consistent.
    /// Returns nil if valid, or a description of what's wrong.
    public var validationError: String? {
        guard !measurements.isEmpty else {
            return "No measurements"
        }

        for m in measurements {
            // Target temp should be in sane range
            if m.targetTemp < 40 || m.targetTemp > 100 {
                return "Target temp \(m.targetTemp)°C is out of range (40-100°C)"
            }
            // Holding RPM should be 0-1
            if m.holdingRPMPercent < 0 || m.holdingRPMPercent > 1 {
                return "Holding RPM \(m.holdingRPMPercent) at \(Int(m.targetTemp))°C is out of range (0-1)"
            }
        }

        // Higher temps should need higher fan speeds
        let sorted = measurements.sorted { $0.targetTemp < $1.targetTemp }
        for i in 0..<(sorted.count - 1) {
            if sorted[i + 1].holdingRPMPercent < sorted[i].holdingRPMPercent - 0.05 {
                return "Fan speed decreases from \(Int(sorted[i].targetTemp))°C to \(Int(sorted[i + 1].targetTemp))°C — data inconsistent"
            }
        }

        return nil
    }

    public var isValid: Bool { validationError == nil }

    /// Interpolate the RPM percentage needed to hold a target temperature under load.
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
        guard FileManager.default.fileExists(atPath: filePath.path) else { return nil }

        guard let data = try? Data(contentsOf: filePath) else {
            TFLogger.shared.error("Calibration file exists but couldn't be read — deleting")
            try? FileManager.default.removeItem(at: filePath)
            return nil
        }

        guard let calibration = try? JSONDecoder().decode(CalibrationData.self, from: data) else {
            TFLogger.shared.error("Calibration file is corrupted (JSON decode failed) — deleting")
            try? FileManager.default.removeItem(at: filePath)
            return nil
        }

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
    /// 5 fan levels × ~100s each + intensity finding + cooldowns ≈ 15 min
    /// 60-second stabilization window (~80% accuracy)
    case quick

    /// 5 fan levels × ~150s each + overhead ≈ 22 min
    /// 90-second window (near one time constant, ~90% accuracy)
    case standard

    /// 5 fan levels × ~200s each + overhead ≈ 30 min
    /// 120-second window (full time constant, ~95% accuracy)
    case optimized

    public var description: String {
        switch self {
        case .quick: return "Quick (up to 15 min)"
        case .standard: return "Standard (up to 22 min)"
        case .optimized: return "Optimized (up to 30 min)"
        }
    }

    /// Ranking for downgrade prevention
    public var rank: Int {
        switch self {
        case .quick: return 1
        case .standard: return 2
        case .optimized: return 3
        }
    }

    /// Number of readings in stabilization window (2s per reading)
    /// Based on thermal time constant research (90-120s):
    /// - Quick: 60s ≈ ~80% of steady state
    /// - Standard: 90s ≈ near one time constant
    /// - Optimized: 120s ≈ one full time constant, ~95% accuracy
    public var stabilizationWindowSize: Int {
        switch self {
        case .quick: return 30      // 60 seconds
        case .standard: return 45   // 90 seconds
        case .optimized: return 60  // 120 seconds
        }
    }

    /// Maximum seconds to wait at each fan level for stabilization
    // Legacy — used by CalibrationView until it's rewritten
    public var heatSeconds: Int { maxWaitPerLevel }
    public var coolSeconds: Int { 30 }

    public var maxWaitPerLevel: Int {
        switch self {
        case .quick: return 150     // 2.5 minutes
        case .standard: return 240  // 4 minutes
        case .optimized: return 360 // 6 minutes
        }
    }

}

/// What to stress during calibration
public enum CalibrationStressType: String, CaseIterable {
    /// CPU + GPU simultaneously — real-world worst case (default)
    case combined
    /// CPU only — isolates CPU thermal contribution
    case cpu
    /// GPU only — isolates GPU thermal contribution (Metal compute)
    case gpu

    public var description: String {
        switch self {
        case .combined: return "CPU + GPU (recommended)"
        case .cpu: return "CPU only"
        case .gpu: return "GPU only"
        }
    }
}

// MARK: - Calibration Runner

public final class CalibrationRunner {
    private let fanControl: FanControl
    private let mode: CalibrationMode
    private let stressType: CalibrationStressType
    private var stressThreads: [Thread] = []
    private let stressLock = NSLock()
    private var _stressRunning = false
    private var stressRunning: Bool {
        get { stressLock.lock(); defer { stressLock.unlock() }; return _stressRunning }
        set { stressLock.lock(); _stressRunning = newValue; stressLock.unlock() }
    }
    private let isoFormatter = ISO8601DateFormatter()

    public var onProgress: ((String) -> Void)?

    /// Path to the CSV log generated during calibration
    public private(set) var logPath: URL?

    // CSV log handle — written to in real time during calibration
    private var csvHandle: FileHandle?

    public init(fanControl: FanControl, mode: CalibrationMode = .standard, stressType: CalibrationStressType = .combined) {
        self.fanControl = fanControl
        self.mode = mode
        self.stressType = stressType
    }

    /// Check if running this mode would downgrade existing calibration
    public static func wouldDowngrade(mode: CalibrationMode) -> Bool {
        guard let existing = CalibrationData.load() else { return false }
        return mode.rank < existing.modeRank
    }

    /// Performance ceiling — stop increasing load if temp reaches this
    private static let performanceCeiling: Float = 85.0

    /// Target heating rate for calibration — matches real-world workloads.
    /// Research: real workloads heat Apple Silicon at ~1-2°C/sec.
    /// Max synthetic load heats at ~5-8°C/sec (Notebookcheck, Max Tech).
    private static let targetHeatingRate: Float = 1.0 // °C/sec

    /// Find the stress intensity that produces ~1°C/sec heating on this machine.
    /// Fans on auto (Apple default). Starts at 1% and adjusts.
    private func findBaselineIntensity() -> Float {
        log("Finding baseline intensity for ~1°C/sec...")

        // Reset fans to auto — we want to measure raw heating without fan interference
        try? fanControl.resetAuto()
        Thread.sleep(forTimeInterval: 2)

        var intensity: Float = 0.01 // Start at 1%
        let maxAttempts = 10

        for attempt in 0..<maxAttempts {
            // Record starting temp
            let startTemp = peakCPUTemp()
            guard startTemp > 0 else {
                log("  Can't read temperature, using default intensity 0.02")
                return 0.02
            }

            // Run stress at current intensity for 10 seconds
            startStress(intensity: intensity)
            Thread.sleep(forTimeInterval: 10)
            stopStress()

            // Measure how much temp rose
            let endTemp = peakCPUTemp()
            let rise = endTemp - startTemp
            let rate = rise / 10.0 // °C/sec

            log("  Attempt \(attempt + 1): intensity \(String(format: "%.3f", intensity)) → \(String(format: "%.2f", rate))°C/sec (\(String(format: "%.1f", startTemp))→\(String(format: "%.1f", endTemp))°C)")

            // Check if we're in the target range (0.8-1.2 °C/sec)
            if rate >= 0.8 && rate <= 1.2 {
                log("  Found baseline: \(String(format: "%.3f", intensity)) at \(String(format: "%.2f", rate))°C/sec")
                return intensity
            }

            // Adjust intensity proportionally
            if rate < 0.1 {
                // Way too low, double it
                intensity = min(intensity * 2, 0.5)
            } else if rate > 0 {
                // Scale proportionally: if rate is 2°C/sec and target is 1, halve intensity
                intensity = intensity * (Self.targetHeatingRate / rate)
                intensity = min(max(intensity, 0.001), 0.5) // clamp to sane range
            } else {
                // No heating detected, increase
                intensity = min(intensity * 3, 0.5)
            }

            // Brief cool between attempts
            Thread.sleep(forTimeInterval: 5)
        }

        log("  Could not converge after \(maxAttempts) attempts, using \(String(format: "%.3f", intensity))")
        return intensity
    }

    /// Read peak CPU temperature right now
    private func peakCPUTemp() -> Float {
        guard let status = try? fanControl.status() else { return 0 }
        return status.temperatures
            .filter { k, _ in k.hasPrefix("TC") || k.hasPrefix("Tp") }
            .values.max() ?? 0
    }

    /// Cleanup: always stop stress, reset fans, close CSV on any exit path
    private func cleanup() {
        stopStress()
        try? fanControl.resetAuto()
        csvHandle?.closeFile()
        csvHandle = nil
    }

    /// Fan levels to test (high to low). 5 levels cover the useful cooling range.
    private static func fanLevels(minPct: Float) -> [Float] {
        [1.0, 0.80, 0.60, 0.45, minPct]
    }

    /// Temperature targets for the control curve output
    private static let controlCurveTemps: [Float] = [60, 65, 70, 75, 80, 85]

    /// Ceiling: record data and skip remaining lower fan levels
    private static let ceilingTemp: Float = 84.0

    /// Safety: abort and max fans
    private static let safetyTemp: Float = 90.0

    /// Run full calibration. Blocks until complete.
    public func run() throws -> CalibrationData {
        defer { cleanup() }

        let fanCount = try fanControl.fanCount()
        let fan0 = try fanControl.fanInfo(0)
        let maxRPM = fan0.maxRPM > 0 ? fan0.maxRPM : 7826
        let minRPM = fan0.minRPM > 0 ? fan0.minRPM : 2317
        let minPct = minRPM / maxRPM

        // Machine info
        var sysSize = 0
        sysctlbyname("hw.model", nil, &sysSize, nil, 0)
        var modelBuf = [CChar](repeating: 0, count: Swift.max(sysSize, 1))
        sysctlbyname("hw.model", &modelBuf, &sysSize, nil, 0)
        let machine = String(cString: modelBuf)

        let levels = Self.fanLevels(minPct: minPct)
        log("Mode: \(mode.description)")
        log("Stress: \(stressType.description)")
        log("Approach: fan-first with stabilization (set fan speed, wait for equilibrium)")
        log("Fan levels: \(levels.map { "\(Int($0 * 100))%" }.joined(separator: " → "))")
        log("Stabilization window: \(mode.stabilizationWindowSize * 2)s, max wait: \(mode.maxWaitPerLevel)s/level")

        // Record ambient temperature
        if let status = try? fanControl.status() {
            let ambient = status.temperatures.filter { k, _ in k.hasPrefix("TA") }.values.first ?? 0
            if ambient > 0 { log("Ambient: \(String(format: "%.1f", ambient))°C") }
        }

        // Phase 0: Cooldown to baseline
        log("Phase 0: Cooling to baseline...")
        waitForCooldown(below: 45)

        // Phase 1: Find stress intensity (~1°C/sec)
        log("Phase 1: Finding baseline intensity...")
        let baselineIntensity = findBaselineIntensity()
        log("Baseline intensity: \(String(format: "%.3f", baselineIntensity))")

        // Phase 1.5: Cool again after intensity finding
        stopStress()
        try fanControl.resetAuto()
        waitForCooldown(below: 45)

        // Set up CSV log
        let logDir = CalibrationData.filePath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let timestamp = isoFormatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let csvURL = logDir.appendingPathComponent("calibration_\(timestamp).csv")
        FileManager.default.createFile(atPath: csvURL.path, contents: nil)
        csvHandle = try FileHandle(forWritingTo: csvURL)
        logPath = csvURL
        csvWrite("timestamp,fan_pct,actual_temp,fan0_rpm,fan1_rpm,phase")

        // Phase 2: Fan-level stabilization sweep (high to low)
        log("Phase 2: Starting fan-level sweep...")
        startStress(intensity: baselineIntensity)

        var rawData: [(fanPct: Float, equilTemp: Float)] = []
        var abortLowerLevels = false

        for fanPct in levels {
            guard !abortLowerLevels else { break }

            let targetRPM = Swift.max(maxRPM * fanPct, minRPM)
            log("[\(Int(fanPct * 100))%] Setting fans to \(Int(targetRPM)) RPM — waiting for stabilization...")

            try fanControl.setAllFans(rpm: targetRPM)

            var readings: [Float] = []
            let deadline = Date().addingTimeInterval(TimeInterval(mode.maxWaitPerLevel))
            var stabilized = false

            while Date() < deadline {
                let temp = peakCPUTemp()
                readings.append(temp)

                // CSV logging
                let fan0rpm = (try? fanControl.fanInfo(0))?.actualRPM ?? 0
                let fan1rpm = fanCount > 1 ? ((try? fanControl.fanInfo(1))?.actualRPM ?? 0) : 0
                let ts = isoFormatter.string(from: Date())
                csvWrite("\(ts),\(String(format: "%.2f", fanPct)),\(String(format: "%.1f", temp)),\(Int(fan0rpm)),\(Int(fan1rpm)),stabilizing")

                // Safety: abort if too hot
                if temp >= Self.safetyTemp {
                    log("[\(Int(fanPct * 100))%] Safety at \(String(format: "%.0f", temp))°C — maxing fans, skipping lower levels")
                    try fanControl.setMax()
                    Thread.sleep(forTimeInterval: 30)
                    rawData.append((fanPct: fanPct, equilTemp: Self.ceilingTemp))
                    abortLowerLevels = true
                    break
                }

                // Ceiling: record and skip lower levels
                if temp >= Self.ceilingTemp {
                    log("[\(Int(fanPct * 100))%] Ceiling reached at \(String(format: "%.1f", temp))°C")
                    rawData.append((fanPct: fanPct, equilTemp: Self.ceilingTemp))
                    abortLowerLevels = true
                    break
                }

                // Check stabilization
                if isStabilized(readings: readings) {
                    let window = readings.suffix(mode.stabilizationWindowSize)
                    let equilTemp = window.reduce(0, +) / Float(window.count)
                    log("[\(Int(fanPct * 100))%] Stabilized at \(String(format: "%.1f", equilTemp))°C (\(readings.count * 2)s)")
                    rawData.append((fanPct: fanPct, equilTemp: equilTemp))
                    stabilized = true
                    break
                }

                Thread.sleep(forTimeInterval: 2)
            }

            // Timeout: use best estimate
            if !stabilized && !abortLowerLevels {
                let windowSize = min(readings.count, mode.stabilizationWindowSize)
                let window = readings.suffix(windowSize)
                let equilTemp = window.isEmpty ? peakCPUTemp() : window.reduce(0, +) / Float(window.count)
                log("[\(Int(fanPct * 100))%] Timeout — best estimate: \(String(format: "%.1f", equilTemp))°C (\(readings.count * 2)s)")
                rawData.append((fanPct: fanPct, equilTemp: equilTemp))
            }
        }

        stopStress()

        // Phase 3: Build control curve from raw equilibrium data
        log("Phase 3: Building control curve...")
        let measurements = buildControlCurve(rawData: rawData, minPct: minPct)

        for m in measurements {
            log("  \(Int(m.targetTemp))°C → \(Int(m.holdingRPMPercent * 100))% fans")
        }

        return CalibrationData(
            machine: machine,
            fans: fanCount,
            maxRPM: Int(maxRPM),
            minRPM: Int(minRPM),
            calibratedAt: isoFormatter.string(from: Date()),
            mode: mode.rawValue,
            measurements: measurements
        )
    }

    /// Wait for machine to cool below a threshold
    /// Check if temperature readings have stabilized.
    /// Stable = stdev < 0.5°C AND slope < 0.05°C/sec over the window.
    private func isStabilized(readings: [Float]) -> Bool {
        guard readings.count >= mode.stabilizationWindowSize else { return false }
        let window = Array(readings.suffix(mode.stabilizationWindowSize))
        let n = Float(window.count)

        // Standard deviation
        let mean = window.reduce(0, +) / n
        let variance = window.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / n
        let stdev = sqrt(variance)

        // Linear regression slope (least squares)
        let xMean = (n - 1) / 2
        var numerator: Float = 0
        var denominator: Float = 0
        for i in 0..<window.count {
            let x = Float(i) - xMean
            let y = window[i] - mean
            numerator += x * y
            denominator += x * x
        }
        let slope = denominator > 0 ? numerator / denominator : 0
        let slopePerSecond = slope / 2.0 // readings are 2 seconds apart

        return stdev < 0.5 && abs(slopePerSecond) < 0.05
    }

    /// Build monotonically increasing control curve from raw equilibrium data.
    /// Raw data: (fanPct, equilTemp) — higher fan = lower equilibrium (physically correct).
    /// Control curve: (targetTemp, holdingRPMPercent) — higher temp = higher fan (for Smart).
    /// Formula: fan_control(T) = (1.0 + minPct) - F_equil(T)
    private func buildControlCurve(rawData: [(fanPct: Float, equilTemp: Float)], minPct: Float) -> [CalibrationData.Measurement] {
        guard rawData.count >= 2 else { return [] }

        // Sort raw data by equilibrium temp ascending
        let sorted = rawData.sorted { $0.equilTemp < $1.equilTemp }

        var measurements: [CalibrationData.Measurement] = []

        for target in Self.controlCurveTemps {
            // Interpolate equilibrium fan speed for this target temp
            let fEquil = interpolateEquilFanSpeed(temp: target, data: sorted)

            // Flip: control fan speed = (1.0 + minPct) - equilibrium fan speed
            var controlFan = (1.0 + minPct) - fEquil
            controlFan = min(max(controlFan, minPct), 1.0)

            measurements.append(CalibrationData.Measurement(
                targetTemp: target,
                holdingRPMPercent: controlFan
            ))
        }

        return measurements
    }

    /// Interpolate the equilibrium fan speed for a given temperature from raw data.
    private func interpolateEquilFanSpeed(temp: Float, data: [(fanPct: Float, equilTemp: Float)]) -> Float {
        guard !data.isEmpty else { return 0.5 }
        if temp <= data.first!.equilTemp { return data.first!.fanPct }
        if temp >= data.last!.equilTemp { return data.last!.fanPct }

        for i in 0..<(data.count - 1) {
            if temp >= data[i].equilTemp && temp <= data[i + 1].equilTemp {
                let t = (temp - data[i].equilTemp) / (data[i + 1].equilTemp - data[i].equilTemp)
                return data[i].fanPct + t * (data[i + 1].fanPct - data[i].fanPct)
            }
        }
        return data.last!.fanPct
    }

    private func waitForCooldown(below threshold: Float) {
        for _ in 0..<60 {
            let temp = peakCPUTemp()
            if temp > 0 && temp < threshold {
                log("Cooled to \(String(format: "%.1f", temp))°C")
                return
            }
            Thread.sleep(forTimeInterval: 2)
        }
    }

    // MARK: - Stress (CPU + GPU combined)
    //
    // Combined stress matches real-world worst case on Apple Silicon where
    // CPU, GPU, and Neural Engine share the same die and unified memory.
    // This is the Notebookcheck standard (Prime95 + FurMark simultaneously).

    /// Start stress at a given intensity (0.0–1.0).
    /// CPU: intensity * coreCount threads active.
    /// GPU: intensity * 4M grid size.
    private func startStress(intensity: Float = 1.0) {
        guard !stressRunning else { return }
        stressRunning = true

        // CPU stress: use intensity * cores
        if stressType == .combined || stressType == .cpu {
            let coreCount = ProcessInfo.processInfo.activeProcessorCount
            let activeCores = Swift.max(Int(Float(coreCount) * intensity), 1)
            for _ in 0..<activeCores {
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

        // GPU stress: scale grid size by intensity
        if stressType == .combined || stressType == .gpu {
            startGPUStress(intensity: intensity)
        }
    }

    private func startGPUStress(intensity: Float = 1.0) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            log("Warning: Metal device not available, running CPU-only stress")
            return
        }

        // Compile a compute shader at runtime that does dense FP32 math
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        kernel void stress(device float *data [[buffer(0)]],
                          uint id [[thread_position_in_grid]]) {
            float x = data[id];
            for (int i = 0; i < 2000; i++) {
                x = sin(x) * cos(x) + tan(x * 0.01);
                x = fma(x, x, float(i) * 0.001);
                x = sqrt(abs(x) + 1.0);
            }
            data[id] = x;
        }
        """

        guard let library = try? device.makeLibrary(source: shaderSource, options: nil),
              let function = library.makeFunction(name: "stress"),
              let pipeline = try? device.makeComputePipelineState(function: function),
              let queue = device.makeCommandQueue()
        else {
            log("Warning: Metal pipeline setup failed, running CPU-only stress")
            return
        }

        // Scale GPU work by intensity — grid size controls utilization
        let baseCount = 1024 * 1024 * 4 // 4M floats at 100%
        let elementCount = Swift.max(Int(Float(baseCount) * intensity), 1024)
        let bufferSize = elementCount * MemoryLayout<Float>.stride
        guard let buffer = device.makeBuffer(length: bufferSize, options: .storageModeShared) else {
            log("Warning: Metal buffer allocation failed, running CPU-only stress")
            return
        }

        // Fill with initial values
        let ptr = buffer.contents().bindMemory(to: Float.self, capacity: elementCount)
        for i in 0..<elementCount {
            ptr[i] = Float(i % 1000) * 0.001
        }

        self.gpuDevice = device
        self.gpuPipeline = pipeline
        self.gpuQueue = queue
        self.gpuBuffer = buffer
        self.gpuElementCount = elementCount

        // Run GPU dispatches on a background thread
        let thread = Thread {
            self.gpuStressLoop()
        }
        thread.qualityOfService = .userInteractive
        thread.start()
        stressThreads.append(thread)
    }

    private var gpuDevice: MTLDevice?
    private var gpuPipeline: MTLComputePipelineState?
    private var gpuQueue: MTLCommandQueue?
    private var gpuBuffer: MTLBuffer?
    private var gpuElementCount: Int = 0

    private func gpuStressLoop() {
        guard let pipeline = gpuPipeline,
              let queue = gpuQueue,
              let buffer = gpuBuffer
        else { return }

        let threadGroupSize = MTLSize(width: pipeline.maxTotalThreadsPerThreadgroup, height: 1, depth: 1)
        let gridSize = MTLSize(width: gpuElementCount, height: 1, depth: 1)

        while stressRunning {
            guard let commandBuffer = queue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeComputeCommandEncoder()
            else { continue }

            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(buffer, offset: 0, index: 0)
            encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadGroupSize)
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }
    }

    private func stopStress() {
        stressRunning = false
        // Wait for threads to notice the flag and exit
        Thread.sleep(forTimeInterval: 2)
        stressThreads.removeAll()
        // Release Metal resources — stops GPU dispatches
        gpuBuffer = nil
        gpuPipeline = nil
        gpuQueue = nil
        gpuDevice = nil
    }

    // MARK: - Helpers

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
