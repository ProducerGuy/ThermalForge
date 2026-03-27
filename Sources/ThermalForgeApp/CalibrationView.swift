//
//  CalibrationView.swift
//  ThermalForge
//
//  In-app calibration UI with progress, live temp, and stop button.
//

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
        // 4 levels × (heat + cool) + pauses
        4 * (selectedMode.heatSeconds + selectedMode.coolSeconds) + 20
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
        task?.cancel()
        timerTask?.cancel()

        // Reset fans to Apple defaults
        try? executor.execute(.resetAuto)

        isRunning = false
        phase = "Stopped"
    }

    private func runCalibration() async {
        let client = DaemonClient()
        let rpmLevels: [(pct: Float, label: String)] = [
            (0.25, "25%"), (0.50, "50%"), (0.75, "75%"), (1.00, "100%")
        ]

        // Get max RPM from status
        var maxRPM: Float = 7826
        if let response = try? client.send("status"),
           let data = response.data(using: .utf8),
           let status = try? JSONDecoder().decode(StatusResponse.self, from: data),
           let fan = status.fans.first {
            maxRPM = Float(fan.maxRPM)
        }

        var measurements: [CalibrationData.Measurement] = []
        let isoFormatter = ISO8601DateFormatter()

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
        csvWrite("timestamp,phase,rpm_pct,fan0_rpm,fan1_rpm,peak_cpu_c,peak_gpu_c,stress_active")

        // Machine info
        var sysSize = 0
        sysctlbyname("hw.model", nil, &sysSize, nil, 0)
        var modelBuf = [CChar](repeating: 0, count: max(sysSize, 1))
        sysctlbyname("hw.model", &modelBuf, &sysSize, nil, 0)
        let machine = String(cString: modelBuf)

        for (_, level) in rpmLevels.enumerated() {
            guard !Task.isCancelled else { break }

            let targetRPM = Int(maxRPM * level.pct)
            await MainActor.run {
                phase = "[\(level.label)] Heating at \(targetRPM) RPM"
            }

            // Set fan speed
            try? client.execute(.setRPM(Float(targetRPM)))

            // Start stress threads
            let stressFlag = StressFlag()
            startStress(flag: stressFlag)

            // Sample heating for 30 seconds
            var heatingReadings: [Float] = []
            for _ in 0..<15 {
                guard !Task.isCancelled else { break }
                let (peak, cpuT, gpuT, f0, f1) = readTemps(client: client)
                heatingReadings.append(peak)
                await MainActor.run { currentTemp = peak }
                csvWrite("\(isoFormatter.string(from: Date())),heating,\(String(format: "%.2f", level.pct)),\(f0),\(f1),\(String(format: "%.1f", cpuT)),\(String(format: "%.1f", gpuT)),true")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }

            let heatingRate = rate(from: heatingReadings)
            let steadyState = heatingReadings.last ?? 0

            // Stop stress, measure cooling
            stressFlag.stop()
            await MainActor.run {
                phase = "[\(level.label)] Cooling at \(targetRPM) RPM"
            }

            var coolingReadings: [Float] = []
            for _ in 0..<10 {
                guard !Task.isCancelled else { break }
                let (peak, cpuT, gpuT, f0, f1) = readTemps(client: client)
                coolingReadings.append(peak)
                await MainActor.run { currentTemp = peak }
                csvWrite("\(isoFormatter.string(from: Date())),cooling,\(String(format: "%.2f", level.pct)),\(f0),\(f1),\(String(format: "%.1f", cpuT)),\(String(format: "%.1f", gpuT)),false")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }

            let coolingRate = rate(from: coolingReadings)

            measurements.append(CalibrationData.Measurement(
                rpmPercent: level.pct,
                coolingRate: coolingRate,
                heatingRate: heatingRate,
                steadyState: steadyState
            ))

            // Brief pause
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }

        csvHandle?.closeFile()

        guard !Task.isCancelled else {
            try? client.execute(.resetAuto)
            return
        }

        // Reset fans
        try? client.execute(.resetAuto)

        // Get fan info for calibration data
        var fanCount = 2
        var minRPM = 0
        if let response = try? client.send("status"),
           let data = response.data(using: .utf8),
           let status = try? JSONDecoder().decode(StatusResponse.self, from: data) {
            fanCount = status.fans.count
            minRPM = status.fans.first?.minRPM ?? 0
        }

        let calibration = CalibrationData(
            machine: machine,
            fans: fanCount,
            maxRPM: Int(maxRPM),
            minRPM: minRPM,
            calibratedAt: isoFormatter.string(from: Date()),
            measurements: measurements
        )
        try? calibration.save()

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

    private func startStress(flag: StressFlag) {
        let coreCount = ProcessInfo.processInfo.activeProcessorCount
        for _ in 0..<coreCount {
            Thread.detachNewThread {
                while flag.running {
                    var x: Double = 1.0
                    for i in 1...10000 { x = sin(x) * cos(Double(i)) }
                    _ = x
                }
            }
        }
    }
}

// Thread-safe stress control
private final class StressFlag: @unchecked Sendable {
    private var _running = true
    var running: Bool { _running }
    func stop() { _running = false }
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
            Text("Quick (~10 min)").tag(CalibrationMode.quick)
            Text("Standard (~28 min)").tag(CalibrationMode.standard)
            Text("Thorough (until stable)").tag(CalibrationMode.thorough)
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
