// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The horizon group's values and their titles, kept out of the AppKit view
/// so the arithmetic can be tested without a window.
///
/// The panel edits `ImmersiveMapSettings.FogSettings` live. The haze range
/// is two sliders over one `ClosedRange`, each keeping the other on its own
/// side, so the range the settings receive is always well formed.
enum DebugOverlayFogSettingsPlanner {
    /// Camera distances. The floor is the resolver's own, under which the
    /// haze would sit under the camera; the ceilings are where the far end
    /// has long since become the horizon line itself.
    static var hazeStartRange: ClosedRange<Double> {
        Double(HorizonFrameResolver.minimumHazeStart)...20
    }

    static let hazeEndRange: ClosedRange<Double> = 0.5...60
    /// The least gap the two ends keep, camera distances.
    static let minimumHazeGap: Float = 0.25

    /// The range with its near end moved: the far end gives way if it has to.
    static func hazeRange(_ range: ClosedRange<Float>, start: Float) -> ClosedRange<Float> {
        let start = max(start, HorizonFrameResolver.minimumHazeStart)
        return start...max(range.upperBound, start + minimumHazeGap)
    }

    /// The range with its far end moved: the near end gives way if it has to.
    static func hazeRange(_ range: ClosedRange<Float>, end: Float) -> ClosedRange<Float> {
        let end = max(end, HorizonFrameResolver.minimumHazeStart + minimumHazeGap)
        return min(range.lowerBound, end - minimumHazeGap)...end
    }

    static func hazeStartTitle(_ start: Float) -> String {
        String(format: "Haze from %.1fx", start)
    }

    static func hazeEndTitle(_ end: Float) -> String {
        String(format: "Haze to %.1fx", end)
    }
}
