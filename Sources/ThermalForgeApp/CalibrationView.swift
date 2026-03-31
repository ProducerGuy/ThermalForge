//
//  CalibrationView.swift
//  ThermalForge
//
//  In-app calibration UI with progress, live temp, and stop button.
//

@preconcurrency import Metal
import SwiftUI
import ThermalForgeCore

// MARK: - Calibration State

@MainActor
final class CalibrationState: ObservableObject {
    @Published var isRunning = false
    @Published var phase = ""
    @Published var currentTemp: Float = 0
    @Published var progress: Float = 0 // 0.0–1.0
    @Published var elapsedSeconds: Int = 0
    @Published var isComplete = false
    @Published var showPrompt = false
    @Published var selectedMode: CalibrationMode = .standard
    @Published var error: String?

    /// Called on main thread when calibration completes successfully
    var onComplete: (() -> Void)?

    private var task: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private let executor = PrivilegedExecutor()

    private var totalSeconds: Int {
        // 6 target temps × (heat to target + binary search + pause) + intensity finding + cooldowns
        6 * (selectedMode.heatSeconds / 2 + 60) + 120
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        isComplete = false
        error = nil
        elapsedSeconds = 0
        progress = 0
        phase = "Starting..."

        // Elapsed timer
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                elapsedSeconds += 1
                progress = min(Float(elapsedSeconds) / Float(totalSeconds), 0.99)
            }
        }

        // Calibration work
        task = Task.detached(priority: .userInitiated) {
            await self.runCalibration()
        }
    }

    func stop() {
        // Kill stress threads first — this is the most important step
        activeStressFlag?.stop()
        activeStressFlag = nil

        // Cancel async tasks
        task?.cancel()
        timerTask?.cancel()

        // Reset fans to Apple defaults
        try? executor.execute(.resetAuto)

        isRunning = false
        phase = "Stopped"
        TFLogger.shared.calibration("Stopped by user — stress killed, fans reset")

        // Notify so AppState can reset profile to Silent
        onStop?()
    }

    /// Called when calibration is stopped — AppState uses this to reset profile
    var onStop: (() -> Void)?

    /// Tracks the current stress flag so stop() can kill threads
    var activeStressFlag: StressFlag?

    private func runCalibration() async {
        let client = DaemonClient()
        let mode = selectedMode
        let isoFormatter = ISO8601DateFormatter()
        let tempTargets: [Float] = [60, 65, 70, 75, 80, 85]

        // Get fan range
        var maxRPM: Float = 7826
        var minRPM: Float = 2317
        if let response = try? client.send("status"),
           let data = response.data(using: .utf8),
           let status = try? JSONDecoder().decode(StatusResponse.self, from: data),
           let fan = status.fans.first {
            maxRPM = Float(fan.maxRPM)
            minRPM = Float(fan.minRPM)
        }
        let minPct = minRPM / maxRPM

        // Machine info
        var sysSize = 0
        sysctlbyname("hw.model", nil, &sysSize, nil, 0)
        var modelBuf = [CChar](repeating: 0, count: max(sysSize, 1))
        sysctlbyname("hw.model", &modelBuf, &sysSize, nil, 0)
        let machine = String(cString: modelBuf)

        // Set up CSV log
        let logDir = CalibrationData.filePath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let timestamp = isoFormatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let csvURL = logDir.appendingPathComponent("calibration_\(timestamp).csv")
        FileManager.default.createFile(atPath: csvURL.path, contents: nil)
        let csvHandle = try? FileHandle(forWritingTo: csvURL)
        func csvWrite(_ line: String) {
            if let d = (line + "\n").data(using: .utf8) { csvHandle?.write(d) }
        }
        csvWrite("timestamp,target_temp,fan_pct,actual_temp,fan0_rpm,fan1_rpm,phase")

        // Wait for cooldown
        await MainActor.run { phase = "Waiting for machine to cool..." }
        for _ in 0..<60 {
            guard !Task.isCancelled else { return }
            let (peak, _, _, _, _) = readTemps(client: client)
            if peak > 0 && peak < 45 { break }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        // Find baseline intensity (~1°C/sec)
        await MainActor.run { phase = "Finding baseline intensity..." }
        let baselineIntensity = await findBaselineIntensity(client: client)
        TFLogger.shared.calibration("Baseline intensity: \(String(format: "%.3f", baselineIntensity))")

        // Cool down after intensity finding
        for _ in 0..<30 {
            guard !Task.isCancelled else { return }
            let (peak, _, _, _, _) = readTemps(client: client)
            if peak > 0 && peak < 45 { break }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        // Start stress at baseline intensity — keep running throughout
        let stressFlag = StressFlag()
        await MainActor.run { activeStressFlag = stressFlag }
        startStress(flag: stressFlag, intensity: baselineIntensity)

        var measurements: [CalibrationData.Measurement] = []

        // For each target temperature, find the fan speed that holds it
        for target in tempTargets {
            guard !Task.isCancelled else { break }

            await MainActor.run { phase = "Heating to \(Int(target))°C..." }

            // Let temp rise to target with fans on auto
            try? client.execute(.resetAuto)
            var reachedTarget = false
            let maxWait = mode.heatSeconds

            for _ in 0..<(maxWait / 2) {
                guard !Task.isCancelled else { break }
                let (peak, _, _, _, _) = readTemps(client: client)
                await MainActor.run { currentTemp = peak }

                let ts = isoFormatter.string(from: Date())
                csvWrite("\(ts),\(Int(target)),0.00,\(String(format: "%.1f", peak)),0,0,heating")

                if peak >= target {
                    reachedTarget = true
                    break
                }
                if peak >= 95 {
                    stressFlag.stop()
                    try? client.execute(.setMax)
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    break
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }

            guard reachedTarget && !Task.isCancelled else { continue }

            // Binary search: find fan speed that holds temp at target
            await MainActor.run { phase = "Finding fan speed for \(Int(target))°C..." }
            var lowPct = minPct
            var highPct: Float = 1.0
            var holdingPct = highPct
            let searchIterations = mode == .quick ? 4 : mode == .standard ? 6 : 8

            for _ in 0..<searchIterations {
                guard !Task.isCancelled else { break }

                let testPct = (lowPct + highPct) / 2
                let testRPM = Swift.max(maxRPM * testPct, minRPM)

                try? client.execute(.setRPM(testRPM))
                try? await Task.sleep(nanoseconds: 3_000_000_000)

                // Safety backstop during search
                let (checkTemp, _, _, _, _) = readTemps(client: client)
                if checkTemp >= 95 {
                    stressFlag.stop()
                    try? client.execute(.setMax)
                    TFLogger.shared.safety("Calibration safety backstop at \(String(format: "%.0f", checkTemp))°C during search")
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    break
                }

                let holdTime = mode == .quick ? 8 : mode == .standard ? 15 : 25
                var readings: [Float] = []
                for _ in 0..<(holdTime / 2) {
                    guard !Task.isCancelled else { break }
                    let (peak, _, _, f0, _) = readTemps(client: client)
                    readings.append(peak)
                    await MainActor.run { currentTemp = peak }

                    let ts = isoFormatter.string(from: Date())
                    csvWrite("\(ts),\(Int(target)),\(String(format: "%.2f", testPct)),\(String(format: "%.1f", peak)),\(f0),0,searching")
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }

                let avgTemp = readings.reduce(0, +) / max(Float(readings.count), 1)
                let trend = readings.count >= 2 ? (readings.last! - readings.first!) : 0

                await MainActor.run {
                    phase = "[\(Int(target))°C] \(Int(testPct * 100))% → \(String(format: "%.1f", avgTemp))°C"
                }

                if avgTemp > target + 1 || trend > 0.5 {
                    lowPct = testPct
                } else if avgTemp < target - 2 && trend < -0.5 {
                    highPct = testPct
                } else {
                    holdingPct = testPct
                    break
                }
                holdingPct = testPct
            }

            TFLogger.shared.calibration("[\(Int(target))°C] Holding speed: \(Int(holdingPct * 100))%")

            measurements.append(CalibrationData.Measurement(
                targetTemp: target,
                holdingRPMPercent: holdingPct
            ))

            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }

        // Cleanup
        stressFlag.stop()
        csvHandle?.closeFile()
        try? client.execute(.resetAuto)
        await MainActor.run { activeStressFlag = nil }

        guard !Task.isCancelled else { return }

        guard !measurements.isEmpty else {
            TFLogger.shared.calibration("No measurements captured")
            await MainActor.run {
                timerTask?.cancel()
                phase = "Failed — no data captured"
                isRunning = false
            }
            return
        }

        var fanCount = 2
        if let response = try? client.send("status"),
           let data = response.data(using: .utf8),
           let status = try? JSONDecoder().decode(StatusResponse.self, from: data) {
            fanCount = status.fans.count
        }

        let calibration = CalibrationData(
            machine: machine,
            fans: fanCount,
            maxRPM: Int(maxRPM),
            minRPM: Int(minRPM),
            calibratedAt: isoFormatter.string(from: Date()),
            mode: mode.rawValue,
            measurements: measurements
        )

        if let error = calibration.validationError {
            TFLogger.shared.error("Calibration data failed validation: \(error)")
            await MainActor.run {
                timerTask?.cancel()
                phase = "Failed — \(error)"
                isRunning = false
            }
            return
        }

        try? calibration.save()
        TFLogger.shared.calibration("Calibration complete — \(measurements.count) temp points saved")

        await MainActor.run {
            timerTask?.cancel()
            progress = 1.0
            phase = "Complete"
            isRunning = false
            isComplete = true
            onComplete?()
        }
    }

    // MARK: - Helpers

    /// Find stress intensity that produces ~1°C/sec heating. Fans on auto.
    private func findBaselineIntensity(client: DaemonClient) async -> Float {
        // Reset fans to auto
        try? client.execute(.resetAuto)
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        var intensity: Float = 0.01
        let targetRate: Float = 1.0

        for attempt in 0..<10 {
            guard !Task.isCancelled else { return 0.02 }

            let (startTemp, _, _, _, _) = readTemps(client: client)
            guard startTemp > 0 else { return 0.02 }

            // Run stress for 10 seconds
            let flag = StressFlag()
            await MainActor.run { activeStressFlag = flag }
            startStress(flag: flag, intensity: intensity)
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            flag.stop()

            let (endTemp, _, _, _, _) = readTemps(client: client)
            let rate = (endTemp - startTemp) / 10.0

            await MainActor.run {
                phase = "Finding intensity: \(String(format: "%.1f", rate))°C/sec (attempt \(attempt + 1))"
            }

            if rate >= 0.8 && rate <= 1.2 {
                return intensity
            }

            if rate < 0.1 {
                intensity = min(intensity * 2, 0.5)
            } else if rate > 0 {
                intensity = intensity * (targetRate / rate)
                intensity = min(max(intensity, 0.001), 0.5)
            } else {
                intensity = min(intensity * 3, 0.5)
            }

            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }

        return intensity
    }

    private func readTemps(client: DaemonClient) -> (peak: Float, cpu: Float, gpu: Float, fan0: Int, fan1: Int) {
        guard let response = try? client.send("status"),
              let data = response.data(using: .utf8),
              let status = try? JSONDecoder().decode(StatusResponse.self, from: data)
        else { return (0, 0, 0, 0, 0) }

        let cpuTemp = status.temperatures
            .filter { k, _ in k.hasPrefix("TC") || k.hasPrefix("Tp") }
            .values.max() ?? 0
        let gpuTemp = status.temperatures
            .filter { k, _ in k.hasPrefix("TG") || k.hasPrefix("Tg") }
            .values.max() ?? 0
        let fan0 = status.fans.first?.actualRPM ?? 0
        let fan1 = status.fans.count > 1 ? status.fans[1].actualRPM : 0

        return (max(cpuTemp, gpuTemp), cpuTemp, gpuTemp, fan0, fan1)
    }

    private func rate(from readings: [Float]) -> Float {
        guard readings.count >= 2 else { return 0 }
        return (readings.last! - readings.first!) / Float(readings.count - 1) / 2.0
    }

    private var gpuPipeline: MTLComputePipelineState?
    private var gpuQueue: MTLCommandQueue?
    private var gpuBuffer: MTLBuffer?
    private var gpuElementCount: Int = 0

    private func startStress(flag: StressFlag, intensity: Float = 1.0) {
        // CPU stress: intensity * cores
        let coreCount = ProcessInfo.processInfo.activeProcessorCount
        let activeCores = max(Int(Float(coreCount) * intensity), 1)
        for _ in 0..<activeCores {
            Thread.detachNewThread {
                while flag.running {
                    var x: Double = 1.0
                    for i in 1...10000 { x = sin(x) * cos(Double(i)) }
                    _ = x
                }
            }
        }

        // GPU stress: Metal compute shader
        guard let device = MTLCreateSystemDefaultDevice() else { return }

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
        else { return }

        let baseCount = 1024 * 1024 * 4
        let elementCount = max(Int(Float(baseCount) * intensity), 1024)
        guard let buffer = device.makeBuffer(length: elementCount * MemoryLayout<Float>.stride, options: .storageModeShared)
        else { return }

        let ptr = buffer.contents().bindMemory(to: Float.self, capacity: elementCount)
        for i in 0..<elementCount { ptr[i] = Float(i % 1000) * 0.001 }

        self.gpuPipeline = pipeline
        self.gpuQueue = queue
        self.gpuBuffer = buffer
        self.gpuElementCount = elementCount

        let threadGroupSize = MTLSize(width: pipeline.maxTotalThreadsPerThreadgroup, height: 1, depth: 1)
        let gridSize = MTLSize(width: elementCount, height: 1, depth: 1)

        Thread.detachNewThread {
            while flag.running {
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
    }
}

// Thread-safe stress control using atomic-like access
final class StressFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _running = true
    var running: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _running
    }
    func stop() {
        lock.lock()
        _running = false
        lock.unlock()
    }
}

// Decodable for daemon status JSON (snake_case)
private struct StatusResponse: Decodable {
    let fans: [Fan]
    let temperatures: [String: Float]

    struct Fan: Decodable {
        let actualRPM: Int
        let maxRPM: Int
        let minRPM: Int

        enum CodingKeys: String, CodingKey {
            case actualRPM = "actual_rpm"
            case maxRPM = "max_rpm"
            case minRPM = "min_rpm"
        }
    }
}

// MARK: - Calibration View

struct CalibrationView: View {
    @ObservedObject var state: CalibrationState
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.showPrompt {
                promptView
            } else if state.isComplete {
                completeView
            } else if state.isRunning {
                runningView
            } else if CalibrationData.exists {
                calibratedView
            } else {
                SectionHeader(title: "CALIBRATION")
                startView
            }
        }
    }

    private var promptView: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "CALIBRATE FOR SMART")

            Text("Smart works best when calibrated to your machine. Only needs to run once.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)

            modePicker

            disclaimerText

            Button(action: {
                state.showPrompt = false
                state.start()
            }) {
                Label("Calibrate Now", systemImage: "gauge.with.dots.needle.33percent")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .padding(.horizontal, 12)

            Button(action: {
                state.showPrompt = false
                appState.activateSmartAfterSkip()
            }) {
                Text("Skip — use default curve")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 12)
        }
    }

    private var startView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Calibrate Smart for this machine.")
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)

            modePicker

            disclaimerText

            Button(action: { state.start() }) {
                Label("Start Calibration", systemImage: "gauge.with.dots.needle.33percent")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .padding(.horizontal, 12)
        }
    }

    private var disclaimerText: some View {
        Text("This will push your CPU to full load and cycle fan speeds. Within normal operating parameters but use at your own risk. Press Stop at any time to cancel safely.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
    }

    private var modePicker: some View {
        Picker("Mode", selection: $state.selectedMode) {
            Text(CalibrationMode.quick.description).tag(CalibrationMode.quick)
            Text(CalibrationMode.standard.description).tag(CalibrationMode.standard)
            Text(CalibrationMode.optimized.description).tag(CalibrationMode.optimized)
        }
        .pickerStyle(.inline)
        .labelsHidden()
        .padding(.horizontal, 12)
    }

    private var calibratedView: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "CALIBRATION")
            Label("Calibrated", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .padding(.horizontal, 12)
        }
    }

    private var runningView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(state.phase)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)

            ProgressView(value: state.progress)
                .padding(.horizontal, 12)

            HStack {
                Text(timeString(state.elapsedSeconds))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(String(format: "%.1f", state.currentTemp))°C")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(tempColor(state.currentTemp))
            }
            .padding(.horizontal, 12)

            Button(action: { state.stop() }) {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .padding(.horizontal, 12)
        }
    }

    private var completeView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Calibration complete", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .padding(.horizontal, 12)
            Text("Smart is now calibrated for this machine.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
        }
    }

    private func timeString(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    private func tempColor(_ temp: Float) -> Color {
        if temp >= 90 { return .red }
        if temp >= 75 { return .orange }
        if temp >= 60 { return .yellow }
        return .primary
    }
}

// Re-export for use in CalibrationView
private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.bottom, 2)
    }
}
