// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// Rules a map style's label sizes follow.
///
/// Label sizes are layout points, so the same value has to stay readable on a
/// dense phone display and on a desktop one. That puts a floor under the type
/// scale: below it a label is present on screen without being readable, which
/// is worse than not drawing it, because it still takes collision space from
/// the labels around it.
enum LabelTypeScale {
    /// Smallest em size a label may be drawn at. Matches the platform floor for
    /// readable interface type; at this size the font's x-height is about six
    /// points.
    static let minimumSizePoints: Float = 11

    /// Applies the floor to a size that a style computed itself (typically from
    /// the tile zoom).
    static func clamped(_ sizePoints: Float) -> Float {
        max(sizePoints, minimumSizePoints)
    }
}
