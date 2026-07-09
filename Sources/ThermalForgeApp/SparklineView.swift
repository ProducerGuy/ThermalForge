//
//  SparklineView.swift
//  ThermalForge
//
//  Canvas-based mini sparkline for temperature and fan RPM history.
//  Draws a filled area chart over the last N samples with optional
//  gradient fill and a current-value label.
//
//  Usage:
//    SparklineView(buffer: appState.cpuSparkline, color: .orange)
//    SparklineView(buffer: appState.fan0Sparkline, color: .blue, unit: "RPM", valueRange: 0...8000)
//

import SwiftUI
import ThermalForgeCore

// MARK: - SparklineView

struct SparklineView: View {
    let buffer: SparklineBuffer
    var color: Color = .orange
    /// Fixed value range (nil = auto-scale from buffer min/max with padding)
    var valueRange: ClosedRange<Float>? = nil
    /// Suffix appended to the current value label (e.g. "°", "RPM")
    var unit: String = "°"
    /// Show the current value as a text label on the right
    var showLabel: Bool = true
    /// Height of the sparkline canvas
    var height: CGFloat = 24

    var body: some View {
        HStack(spacing: 4) {
            Canvas { ctx, size in
                guard buffer.values.count >= 2 else { return }
                let values = buffer.values

                // Determine y-axis range
                let lo: Float
                let hi: Float
                if let range = valueRange {
                    lo = range.lowerBound
                    hi = range.upperBound
                } else {
                    let bufMin = values.min() ?? 0
                    let bufMax = values.max() ?? 1
                    let pad = max((bufMax - bufMin) * 0.15, 2)
                    lo = max(bufMin - pad, 0)
                    hi = bufMax + pad
                }
                let span = hi - lo
                guard span > 0 else { return }

                let w = size.width
                let h = size.height
                let step = w / CGFloat(values.count - 1)

                func xPos(_ i: Int) -> CGFloat { CGFloat(i) * step }
                func yPos(_ v: Float) -> CGFloat {
                    let clamped = max(lo, min(hi, v))
                    return h - CGFloat((clamped - lo) / span) * h
                }

                // Build line path
                var linePath = Path()
                linePath.move(to: CGPoint(x: xPos(0), y: yPos(values[0])))
                for i in 1..<values.count {
                    linePath.addLine(to: CGPoint(x: xPos(i), y: yPos(values[i])))
                }

                // Build fill path (close down to bottom)
                var fillPath = linePath
                fillPath.addLine(to: CGPoint(x: xPos(values.count - 1), y: h))
                fillPath.addLine(to: CGPoint(x: 0, y: h))
                fillPath.closeSubpath()

                // Draw gradient fill
                ctx.fill(
                    fillPath,
                    with: .linearGradient(
                        Gradient(colors: [color.opacity(0.35), color.opacity(0.05)]),
                        startPoint: CGPoint(x: 0, y: 0),
                        endPoint: CGPoint(x: 0, y: h)
                    )
                )

                // Draw line on top
                ctx.stroke(linePath, with: .color(color), lineWidth: 1.5)

                // Draw endpoint dot
                if let last = values.last {
                    let dotCenter = CGPoint(x: xPos(values.count - 1), y: yPos(last))
                    let dotRect = CGRect(x: dotCenter.x - 2, y: dotCenter.y - 2, width: 4, height: 4)
                    ctx.fill(Path(ellipseIn: dotRect), with: .color(color))
                }
            }
            .frame(height: height)

            if showLabel, let last = buffer.last {
                Text(labelText(last))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(color)
                    .frame(width: labelWidth, alignment: .trailing)
            }
        }
    }

    private func labelText(_ value: Float) -> String {
        if unit == "RPM" {
            return "\(Int(value))\(unit)"
        }
        return "\(Int(value))\(unit)"
    }

    private var labelWidth: CGFloat {
        unit == "RPM" ? 52 : 30
    }
}

// MARK: - TempSparkline convenience

/// Convenience wrapper pre-configured for temperature display.
struct TempSparkline: View {
    let buffer: SparklineBuffer
    var fahrenheit: Bool = false
    var color: Color = .orange
    var height: CGFloat = 20

    var body: some View {
        let displayBuffer = fahrenheit ? convertedBuffer : buffer
        SparklineView(
            buffer: displayBuffer,
            color: color,
            valueRange: fahrenheit ? (32...230) : (0...110),
            unit: fahrenheit ? "°F" : "°C",
            showLabel: true,
            height: height
        )
    }

    private var convertedBuffer: SparklineBuffer {
        var b = SparklineBuffer(capacity: buffer.capacity)
        for v in buffer.values {
            b.append(v * 9 / 5 + 32)
        }
        return b
    }
}

// MARK: - Preview helper (compile-time only)

#if DEBUG
private struct SparklinePreview: View {
    @State private var buffer: SparklineBuffer = {
        var b = SparklineBuffer(capacity: 60)
        // Simulate a thermal ramp
        var temp: Float = 52
        for _ in 0..<60 {
            temp += Float.random(in: -0.5...1.2)
            temp = max(45, min(95, temp))
            b.append(temp)
        }
        return b
    }()

    var body: some View {
        VStack(spacing: 8) {
            SparklineView(buffer: buffer, color: .orange, unit: "°C")
                .frame(width: 200)
            SparklineView(buffer: buffer, color: .blue, valueRange: 0...8000, unit: "RPM")
                .frame(width: 200)
        }
        .padding()
    }
}
#endif
