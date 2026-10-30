// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMap
import Foundation

/// The Relief tab's Surroundings group: the ranges and titles of the
/// sliders that tune how the country around the camera is read as
/// mountains or a plain (`TerrainSurroundingsSettings`), kept out of the
/// AppKit view so they can be tested without a window. The panel edits the
/// settings live and shows the reading in the tab's summary.
enum DebugOverlayTerrainSurroundingsSettingsPlanner {
    /// From a hill's worth of ground to a whole range.
    static let sampleRadiusRange: ClosedRange<Double> = 250...20000
    /// The spans the thresholds are set among: the lowlands span under a
    /// hundred metres over a few kilometres, the high mountains thousands.
    static let plainBelowRange: ClosedRange<Double> = 0...1500
    static let mountainsAboveRange: ClosedRange<Double> = 0...3000
    static let smoothingHalfLifeRange: ClosedRange<Double> = 0...3

    static func sampleRadiusTitle(_ metres: Float) -> String {
        String(format: "Radius %.0f m", metres)
    }

    static func plainBelowTitle(_ metres: Float) -> String {
        String(format: "Plain below %.0f m", metres)
    }

    static func mountainsAboveTitle(_ metres: Float) -> String {
        String(format: "Mountains above %.0f m", metres)
    }

    static func smoothingHalfLifeTitle(_ seconds: TimeInterval) -> String {
        String(format: "Smoothing %.2f s", seconds)
    }
}
