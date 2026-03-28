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
        /// Fan speed as fraction of max RPM (0.0–1.0)
        public let rpmPercent: Float
        /// Cooling rate in °C/sec (negative = cooling)
        public let coolingRate: Float
        /// Heating rate under load in °C/sec (positive = heating)
        public let heatingRate: Float
        /// Temperature at the highest load step this fan speed sustained below 85°C
        public let steadyState: Float
        /// Maximum load (0.0–1.0) this fan speed held below 85°C. 1.0 = full load.
        public let maxSustainableLoad: Float?

        public init(rpmPercent: Float, coolingRate: Float, heatingRate: Float, steadyState: Float, maxSustainableLoad: Float? = nil) {
            self.rpmPercent = rpmPercent
            self.coolingRate = coolingRate
            self.heatingRate = heatingRate
            self.steadyState = steadyState
            self.maxSustainableLoad = maxSustainableLoad
        }
    }

    /// Validate that calibration data is physically consistent.
    /// Returns nil if valid, or a description of what's wrong.
    public var validationError: String? {
        guard !measurements.isEmpty else {
            return "No measurements"
        }

        for m in measurements {
            // Heating rate should be positive (temps rise under load)
            if m.heatingRate <= 0 {
                return "Heating rate \(m.heatingRate) at \(Int(m.rpmPercent * 100))% is not positive"
            }
            // Cooling rate should be negative (temps drop without load)
            if m.coolingRate >= 0 {
                return "Cooling rate \(m.coolingRate) at \(Int(m.rpmPercent * 100))% is not negative"
            }
            // Steady state should be in a sane range
            if m.steadyState < 20 || m.steadyState > 105 {
                return "Steady state \(m.steadyState)°C at \(Int(m.rpmPercent * 100))% is out of range (20-105°C)"
            }
            // Heating rate shouldn't be insane
            if m.heatingRate > 5 {
                return "Heating rate \(m.heatingRate)°C/s at \(Int(m.rpmPercent * 100))% is unreasonably high"
            }
        }

        // Steady-state temps should generally decrease as RPM increases
        // (more fan = more cooling = lower steady state)
        let sorted = measurements.sorted { $0.rpmPercent < $1.rpmPercent }
        for i in 0..<(sorted.count - 1) {
            if sorted[i + 1].steadyState > sorted[i].steadyState + 5 {
                // Allow small inversions (noise) but not large ones
                return "Steady state increases from \(Int(sorted[i].rpmPercent * 100))% to \(Int(sorted[i + 1].rpmPercent * 100))% — data inconsistent"
            }
        }

        return nil
    }

    public var isValid: Bool { validationError == nil }

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
    case optimized

    public var description: String {
        switch self {
        case .quick: return "Quick (~10 min)"
        case .standard: return "Standard (~28 min)"
        case .optimized: return "Optimized (until stable, ~35-50 min)"
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

    /// Heat phase duration in seconds per level
    public var heatSeconds: Int {
        switch self {
        case .quick: return 120       // 2 min
        case .standard: return 300    // 5 min
        case .optimized: return 600   // 10 min max, exits early on steady state
        }
    }

    /// Cool phase duration in seconds per level
    public var coolSeconds: Int {
        switch self {
        case .quick: return 30
        case .standard: return 120    // 2 min
        case .optimized: return 300   // 5 min max, exits early on steady state
        }
    }

    /// Whether to use steady-state detection to exit phases early
    public var usesSteadyStateDetection: Bool {
        self == .optimized
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

    /// Load steps: 25%, 50%, 75%, 100%
    private static let loadSteps: [Float] = [0.25, 0.50, 0.75, 1.00]

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
        log("Stress: \(stressType.description)")
        log("Ceiling: \(Self.performanceCeiling)°C")

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
        csvWrite("timestamp,phase,rpm_pct,load_pct,fan0_rpm,fan1_rpm,peak_cpu_c,peak_gpu_c")

        // Calculate RPM levels — ensure none go below machine minimum
        let rpmLevels: [(pct: Float, label: String)] = ([0.25, 0.50, 0.75, 1.00] as [Float]).map { pct in
            let targetRPM = maxRPM * pct
            if targetRPM < minRPM {
                let adjusted = minRPM / maxRPM
                return (adjusted, "\(Int(adjusted * 100))% (min)")
            }
            return (pct, "\(Int(pct * 100))%")
        }
        var measurements: [CalibrationData.Measurement] = []

        for level in rpmLevels {
            let pct = level.pct
            let targetRPM = maxRPM * pct
            let label = level.label

            log("[\(label)] Setting fans to \(Int(targetRPM)) RPM")
            try fanControl.setAllFans(rpm: targetRPM)

            // Ramp load through steps, monitoring temp at each
            var maxLoad: Float = 0
            var peakTemp: Float = 0
            var hitCeiling = false
            var allReadings: [Float] = []

            for loadStep in Self.loadSteps {
                let loadLabel = "\(Int(loadStep * 100))%"
                log("[\(label)] Load \(loadLabel) — ramping stress")

                // Start stress at this intensity
                stopStress()
                startStress(intensity: loadStep)

                // Sample at this load step
                let ticksPerStep = mode.heatSeconds / (Self.loadSteps.count * 2)
                let maxTicks = Swift.max(ticksPerStep, 5) // at least 10 seconds

                var stepReadings: [Float] = []
                for _ in 0..<maxTicks {
                    if let status = try? fanControl.status() {
                        let cpuTemp = status.temperatures
                            .filter { k, _ in k.hasPrefix("TC") || k.hasPrefix("Tp") }
                            .values.max() ?? 0
                        let gpuTemp = status.temperatures
                            .filter { k, _ in k.hasPrefix("TG") || k.hasPrefix("Tg") }
                            .values.max() ?? 0
                        let temp = Swift.max(cpuTemp, gpuTemp)
                        stepReadings.append(temp)
                        allReadings.append(temp)

                        let fan0rpm = status.fans.first.map { $0.actualRPM } ?? 0
                        let fan1rpm = status.fans.count > 1 ? status.fans[1].actualRPM : 0
                        let ts = isoFormatter.string(from: Date())
                        csvWrite("\(ts),heating,\(String(format: "%.2f", pct)),\(String(format: "%.2f", loadStep)),\(fan0rpm),\(fan1rpm),\(String(format: "%.1f", cpuTemp)),\(String(format: "%.1f", gpuTemp))")

                        // 85°C ceiling — this fan speed can't hold the line at this load
                        if temp >= Self.performanceCeiling {
                            log("[\(label)] Hit \(String(format: "%.0f", temp))°C at \(loadLabel) load — ceiling reached")
                            hitCeiling = true
                            peakTemp = temp
                            maxLoad = loadStep
                            break
                        }

                        peakTemp = Swift.max(peakTemp, temp)
                    }
                    Thread.sleep(forTimeInterval: 2)

                    // Optimized mode: check if temp stabilized at this load step
                    if mode.usesSteadyStateDetection && stepReadings.count >= 15 {
                        let recent = stepReadings.suffix(15)
                        if (recent.max() ?? 0) - (recent.min() ?? 0) < 0.5 {
                            log("[\(label)] Steady state at \(loadLabel) load: \(String(format: "%.1f", stepReadings.last ?? 0))°C")
                            break
                        }
                    }
                }

                if hitCeiling { break }
                maxLoad = loadStep
            }

            // Stop stress, measure cooling
            stopStress()

            if !hitCeiling {
                log("[\(label)] Handled full load — peak \(String(format: "%.1f", peakTemp))°C")
            }

            // Cooling phase
            log("[\(label)] Cooling at \(Int(targetRPM)) RPM...")
            let coolTicks = mode.coolSeconds / 2
            var coolingReadings: [Float] = []
            for _ in 0..<coolTicks {
                if let status = try? fanControl.status() {
                    let cpuTemp = status.temperatures
                        .filter { k, _ in k.hasPrefix("TC") || k.hasPrefix("Tp") }
                        .values.max() ?? 0
                    let gpuTemp = status.temperatures
                        .filter { k, _ in k.hasPrefix("TG") || k.hasPrefix("Tg") }
                        .values.max() ?? 0
                    let temp = Swift.max(cpuTemp, gpuTemp)
                    coolingReadings.append(temp)

                    let fan0rpm = status.fans.first.map { $0.actualRPM } ?? 0
                    let fan1rpm = status.fans.count > 1 ? status.fans[1].actualRPM : 0
                    let ts = isoFormatter.string(from: Date())
                    csvWrite("\(ts),cooling,\(String(format: "%.2f", pct)),0.00,\(fan0rpm),\(fan1rpm),\(String(format: "%.1f", cpuTemp)),\(String(format: "%.1f", gpuTemp))")
                }
                Thread.sleep(forTimeInterval: 2)
            }

            let heatingRate = rateFromReadings(allReadings)
            let coolingRate = rateFromReadings(coolingReadings)
            let steadyState = peakTemp

            log("[\(label)] Heating rate: \(String(format: "%.2f", heatingRate))°C/s, cooling: \(String(format: "%.2f", coolingRate))°C/s, max load: \(Int(maxLoad * 100))%")

            measurements.append(CalibrationData.Measurement(
                rpmPercent: pct,
                coolingRate: coolingRate,
                heatingRate: heatingRate,
                steadyState: steadyState,
                maxSustainableLoad: maxLoad
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
            mode: mode.rawValue,
            measurements: measurements
        )
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

    // MARK: - Sampling

    /// Sample for up to maxSeconds. In Optimized mode, exits early if steady state detected.
    /// Steady state: temperature change <0.5°C over the last 60 seconds (30 readings).
    private func samplePhase(maxSeconds: Int, phase: String, rpmPct: Float, stressActive: Bool) -> (readings: [Float], safetyTriggered: Bool) {
        var readings: [Float] = []
        var safetyHit = false
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

                // Safety override: 95°C — stop stress, max fans, cool down
                if stressActive && peakTemp >= 95.0 {
                    log("  SAFETY: \(String(format: "%.0f", peakTemp))°C — stopping stress, maxing fans, level discarded")
                    stopStress()
                    try? fanControl.setMax()
                    Thread.sleep(forTimeInterval: 10)
                    safetyHit = true
                    break
                }

                // Steady-state detection for Optimized mode
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
        return (readings, safetyHit)
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
