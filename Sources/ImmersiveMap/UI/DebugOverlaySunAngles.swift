// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Azimuth/elevation of the static sun, and the world direction it stands for.
///
/// `SceneLightSettings.direction` points **towards** the sun in the flat basis
/// (+X east, +Y north, +Z up), so the two angles map onto it directly: azimuth
/// is the compass bearing of the sun (0 north, 90 east), elevation its height
/// above the horizon. A low elevation throws long shadows.
///
/// The debug panel edits the angles rather than the vector because dragging a
/// slider through a raw XYZ direction is not a thing anyone can aim.
enum DebugOverlaySunAngles {
    static func direction(azimuthDegrees: Double, elevationDegrees: Double) -> SIMD3<Float> {
        let azimuth = azimuthDegrees * .pi / 180
        let elevation = elevationDegrees * .pi / 180
        return SIMD3<Float>(Float(cos(elevation) * sin(azimuth)),
                            Float(cos(elevation) * cos(azimuth)),
                            Float(sin(elevation)))
    }

    /// The inverse. A degenerate direction reads as the overhead sun rather
    /// than as a NaN that would travel into a slider.
    static func angles(direction: SIMD3<Float>) -> (azimuthDegrees: Double, elevationDegrees: Double) {
        let length = Double(simd_length(direction))
        guard length > 1e-6, length.isFinite else {
            return (0, 90)
        }
        let x = Double(direction.x) / length
        let y = Double(direction.y) / length
        let z = Double(direction.z) / length
        let azimuth = atan2(x, y) * 180 / .pi
        return (azimuth < 0 ? azimuth + 360 : azimuth,
                asin(min(max(z, -1), 1)) * 180 / .pi)
    }
}
