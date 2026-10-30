// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMap
import Foundation

/// The globe light group's graph axes, ranges and titles, kept out of the
/// AppKit view so they can be tested without a window. The panel edits
/// `ImmersiveMapSettings.GlobeLightSettings` live.
enum DebugOverlayGlobeLightSettingsPlanner {
    /// The strength over the zoom, 0 to 1, on a graph like the air's.
    static let strengthAxes = DebugOverlayZoomCurveAxes(zoomRange: DebugOverlayGroundFogSettingsPlanner.zoomRange,
                                                        valueRange: 0...1)
    /// The terminator's softness in the cosine of the sun's angle: a hard
    /// line at the bottom, a half globe of dusk at the top.
    static let softnessRange: ClosedRange<Double> = 0.01...1
    /// Where the sun stands overhead.
    static let subsolarLatitudeRange: ClosedRange<Double> = -90...90
    static let subsolarLongitudeRange: ClosedRange<Double> = -180...180

    static func strengthTitle(_ strength: ImmersiveMapZoomCurve, cameraZoom: Double) -> String {
        strengthText(Double(strength.value(atZoom: cameraZoom, interpolation: strengthAxes.interpolation)))
    }

    static func strengthText(_ strength: Double) -> String {
        String(format: "Strength %.2f", strength)
    }

    static func softnessTitle(_ softness: Float) -> String {
        String(format: "Terminator softness %.2f", softness)
    }

    static func subsolarLatitudeTitle(_ degrees: Float) -> String {
        String(format: "Sun latitude %.0f°", degrees)
    }

    static func subsolarLongitudeTitle(_ degrees: Float) -> String {
        String(format: "Sun longitude %.0f°", degrees)
    }
}
