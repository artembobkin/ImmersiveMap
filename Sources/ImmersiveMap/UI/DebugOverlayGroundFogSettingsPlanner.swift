// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The ground fog group's ranges and titles, kept out of the AppKit view so
/// they can be tested without a window. The panel edits
/// `ImmersiveMapSettings.GroundFogSettings` live.
enum DebugOverlayGroundFogSettingsPlanner {
    /// Per camera distance at the ground: a veil at the bottom, a wall at
    /// the top.
    static let densityRange: ClosedRange<Double> = 0...3
    /// Camera distances: a film on the ground to a fog over the rooftops.
    static let heightRange: ClosedRange<Double> = 0.01...1
    /// Camera distances from the eye.
    static let startDistanceRange: ClosedRange<Double> = 0...20
    static let maximumOpacityRange: ClosedRange<Double> = 0...1

    static func densityTitle(_ density: Float) -> String {
        String(format: "Density %.2f", density)
    }

    static func heightTitle(_ height: Float) -> String {
        String(format: "Height %.2fx", height)
    }

    static func startDistanceTitle(_ distance: Float) -> String {
        String(format: "From %.1fx", distance)
    }

    static func maximumOpacityTitle(_ opacity: Float) -> String {
        String(format: "Most opacity %.2f", opacity)
    }
}
