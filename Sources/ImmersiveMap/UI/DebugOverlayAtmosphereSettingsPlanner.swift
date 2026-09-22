// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The atmosphere group's ranges and titles, kept out of the AppKit view so
/// they can be tested without a window. The panel edits
/// `ImmersiveMapSettings.AtmosphereSettings` live; the ranges are the ones
/// the settings document as useful rather than everything they accept.
enum DebugOverlayAtmosphereSettingsPlanner {
    /// 1 is the designed look, 0 leaves the sphere bare with the layer on.
    static let intensityRange: ClosedRange<Double> = 0...2
    /// Relative to the designed halo width; the resolver floors it at 0.05.
    static let thicknessRange: ClosedRange<Double> = 0.25...3
    static let sunInfluenceRange: ClosedRange<Double> = 0...1

    static func intensityTitle(_ intensity: Float) -> String {
        String(format: "Intensity %.2f", intensity)
    }

    static func thicknessTitle(_ thickness: Float) -> String {
        String(format: "Thickness %.2fx", thickness)
    }

    static func sunInfluenceTitle(_ influence: Float) -> String {
        String(format: "Sun influence %.2f", influence)
    }
}
