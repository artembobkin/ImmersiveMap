// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The shadow group's values and their titles, kept out of the AppKit view so
/// the arithmetic can be tested without a window.
///
/// The panel edits `ImmersiveMapSettings.ShadowSettings` live. Ranges are the
/// ones that are useful to drag through rather than the full settable range:
/// coverage stops at 12 camera distances because one shadow map is stretched
/// over whatever is asked for, so past that the texels are too coarse to judge
/// anything by, and the map size is a ladder of powers of two because those
/// are the only sizes worth comparing.
enum DebugOverlayShadowSettingsPlanner {
    static let mapResolutions = [512, 1024, 2048, 4096]
    static let mapResolutionTitles = ["512", "1K", "2K", "4K"]
    static let strengthRange: ClosedRange<Double> = 0...1
    static let coverageRange: ClosedRange<Double> = 2...12
    /// The resolver's own clamp, so the slider can reach everything the
    /// setting accepts and nothing it does not: a slider that runs past the
    /// clamp reports a value the renderer is not using.
    static var normalOffsetRange: ClosedRange<Double> {
        let range = ShadowFrameStateResolver.normalOffsetTexelsRange
        return Double(range.lowerBound)...Double(range.upperBound)
    }
    static let azimuthRange: ClosedRange<Double> = 0...360
    /// The resolver drops shadows below a light elevation of ~3 degrees
    /// (`minimumLightDirectionZ`), so the slider stops well above it: a slider
    /// whose bottom end silently turns the feature off reads as a bug.
    static let elevationRange: ClosedRange<Double> = 5...85

    /// Index of the ladder step at or above the current resolution, so an
    /// arbitrary value set in code still selects a segment.
    static func mapResolutionIndex(for resolution: Int) -> Int {
        if let exact = mapResolutions.firstIndex(of: resolution) {
            return exact
        }
        let nearest = mapResolutions.enumerated().min { lhs, rhs in
            abs(lhs.element - resolution) < abs(rhs.element - resolution)
        }
        return nearest?.offset ?? 0
    }

    static func mapResolution(atIndex index: Int) -> Int {
        guard mapResolutions.indices.contains(index) else {
            return mapResolutions[0]
        }
        return mapResolutions[index]
    }

    static func strengthTitle(_ strength: Float) -> String {
        String(format: "Strength %.2f", strength)
    }

    static func coverageTitle(_ coverage: Float) -> String {
        String(format: "Coverage %.1fx", coverage)
    }

    static func normalOffsetTitle(_ texels: Float) -> String {
        String(format: "Normal offset %.1ftx", texels)
    }

    static func azimuthTitle(_ degrees: Double) -> String {
        String(format: "Sun azimuth %.0f°", degrees)
    }

    static func elevationTitle(_ degrees: Double) -> String {
        String(format: "Sun elevation %.0f°", degrees)
    }
}
