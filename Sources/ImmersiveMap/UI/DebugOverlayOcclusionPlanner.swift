// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The arithmetic behind the debug panel's AO tab
/// (`ImmersiveMapTerrainOcclusion`): the radius slider runs
/// geometrically from 100 m to 20 km, so a hill's folds and a wide
/// valley are both a short drag away, and the directions and the
/// resolution come as the steps of a picker.
enum DebugOverlayOcclusionPlanner {
    static let radiusRangeMetres: ClosedRange<Float> = 100 ... 20_000
    static let directionsOptions = [4, 8, 16, 32]
    static let resolutionOptions = [64, 128, 256, 512]

    /// The slider's 0...1 for a radius in metres, geometric over the range.
    static func sliderValue(radiusMetres: Float) -> Double {
        let range = radiusRangeMetres
        let clamped = min(max(radiusMetres, range.lowerBound), range.upperBound)
        return Double(log(clamped / range.lowerBound) / log(range.upperBound / range.lowerBound))
    }

    /// The radius in metres for a slider's 0...1, rounded to three digits.
    static func radiusMetres(sliderValue: Double) -> Float {
        let range = radiusRangeMetres
        let value = range.lowerBound * pow(range.upperBound / range.lowerBound, Float(min(max(sliderValue, 0), 1)))
        let magnitude = pow(10, (log10(value) - 2).rounded(.down))
        return (value / magnitude).rounded() * magnitude
    }

    static func directionsIndex(for directions: Int) -> Int {
        directionsOptions.firstIndex(of: directions) ?? directionsOptions.indices.min { abs(directionsOptions[$0] - directions) < abs(directionsOptions[$1] - directions) } ?? 1
    }

    static func resolutionIndex(for resolution: Int) -> Int {
        resolutionOptions.firstIndex(of: resolution) ?? resolutionOptions.indices.min { abs(resolutionOptions[$0] - resolution) < abs(resolutionOptions[$1] - resolution) } ?? 1
    }

    static func strengthTitle(_ strength: Float) -> String {
        "Strength \(String(format: "%.2f", strength))"
    }

    static func radiusTitle(_ radiusMetres: Float) -> String {
        radiusMetres >= 1000
            ? "Radius \(String(format: "%.1f", radiusMetres / 1000)) km"
            : "Radius \(String(format: "%.0f", radiusMetres)) m"
    }
}
