// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Fragment clip rectangle in the source tile's local coordinates (0..4096).
/// A retained substitution draws the source tile in full at its own origin; without
/// the clip, content beyond the `placeIn` slot would overlap neighboring exact tiles
/// (in the globe atlas the same role is played by cell scissors and shader discard).
enum TileLocalClipMath {
    static let tileExtent: Float = TileCoordinateSpace.tileExtent

    /// Disabled clip: exact placements draw in full, including the stitching
    /// geometry margin beyond 0..4096.
    static let disabledBounds = SIMD4<Float>(-Float.greatestFiniteMagnitude,
                                             -Float.greatestFiniteMagnitude,
                                             Float.greatestFiniteMagnitude,
                                             Float.greatestFiniteMagnitude)

    /// (minX, minY, maxX, maxY) of the `placeIn` region inside `source` in the
    /// source tile's local units. For `placeIn == source` the clip is disabled.
    /// The parser stores vertices with a Y flip (`tileExtent - y`): local y=0 is
    /// the SOUTHERN edge of the tile while the tile index y grows southward, so
    /// the region's y range is mirrored around tileExtent.
    static func clipBounds(source: Tile, placeIn: Tile) -> SIMD4<Float> {
        let depth = placeIn.z - source.z
        guard depth > 0, depth < 30 else {
            return disabledBounds
        }

        let cellSize = tileExtent / Float(1 << depth)
        let offsetX = Float(placeIn.x - (source.x << depth))
        let offsetY = Float(placeIn.y - (source.y << depth))
        return SIMD4<Float>(offsetX * cellSize,
                            tileExtent - (offsetY + 1) * cellSize,
                            (offsetX + 1) * cellSize,
                            tileExtent - offsetY * cellSize)
    }
}
