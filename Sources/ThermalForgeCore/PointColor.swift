//
//  PointColor.swift
//  ThermalForge
//
//  Optional per-point color for a Custom Curve (1D or 2D): once the fan's ACTUAL
//  speed reaches a colored point's fan%, the menu bar icon switches to that color —
//  a simple "zone" indicator (e.g. green under 40%, orange 40-70%, red above) built
//  from data the curve already has, not a separate color-zone model.
//

import Foundation

/// A color, stored as plain sRGB components (0...1) so Core stays platform-
/// independent — no `SwiftUI.Color`/`NSColor` dependency here. The app layer
/// converts to/from `Color` at the editor and menu bar boundary.
public struct PointColor: Codable, Equatable, Hashable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// A curve point that may carry a `PointColor` — implemented by both `FanCurvePoint`
/// (1D) and `FanCurvePoint2D` (2D) so `FanProfile.color(forActualFanPercent:)` has
/// one matching algorithm instead of duplicating it per curve type.
public protocol ColorZonePoint {
    var fanPercent: Float { get }
    var color: PointColor? { get }
}

extension FanProfile {
    /// The color of the highest-fanPercent colored point that the fan's ACTUAL
    /// current speed has reached or passed, or nil if this isn't a Custom Profile,
    /// no point has a color, or none has been reached yet.
    ///
    /// "Reached" uses the real fan speed (not the profile's target), so the icon
    /// tracks what the fan is actually doing — e.g. still ramping up under a governed
    /// increase, or coasting down — not what it's heading toward.
    public func color(forActualFanPercent actualFanPercent: Float) -> PointColor? {
        if let curve = customCurve2D {
            return Self.colorZone(forActualFanPercent: actualFanPercent, points: curve.points)
        }
        if let curve = customCurve {
            return Self.colorZone(forActualFanPercent: actualFanPercent, points: curve.points)
        }
        return nil
    }

    private static func colorZone<P: ColorZonePoint>(
        forActualFanPercent actualFanPercent: Float, points: [P]
    ) -> PointColor? {
        points
            .filter { $0.color != nil && $0.fanPercent <= actualFanPercent }
            .max { $0.fanPercent < $1.fanPercent }?
            .color
    }
}
