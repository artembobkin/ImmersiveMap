// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Nominal display scale for point-locked dash patterns.
///
/// A dash pattern must be anchored to the geometry: if its period follows the
/// live camera, every dash boundary sits at a multiple of a moving number and
/// the whole pattern crawls along the line while the camera pans, rotates or
/// zooms. So the period is fixed in tile units per draw, converted from the
/// style's points at the scale the tile has when it is the native level and
/// the fractional-zoom dolly sits at its far point: camera distance 1 with
/// the render camera's vertical fov of pi/4 (`RenderCamera`). That depends
/// only on the viewport and the tile, never on camera state, so the dashes
/// stay glued to the map; their on-screen size starts at the styled points
/// and breathes with the fractional zoom like every other map feature.
enum LineDashNominalScale {
    /// Tile units per device pixel for geometry of a tile whose world-space
    /// size is `sourceTileWorldSize` (substitutes span more world than a
    /// native tile and get proportionally fewer units per pixel, keeping
    /// their dash size aligned with the tiles they stand in for).
    static func unitsPerPixel(sourceTileWorldSize: Float, drawableHeightPx: Float) -> Float {
        guard sourceTileWorldSize > 0, drawableHeightPx > 0 else { return 0 }
        return 4096.0 * 2.0 * tan(Float.pi / 8.0) / (drawableHeightPx * sourceTileWorldSize)
    }
}
