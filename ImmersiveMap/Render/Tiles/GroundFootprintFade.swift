// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The footprint fade of the flat ground fills: the vector map's stand-in
/// for a mipmap. A screen pixel covers a patch of ground (its footprint);
/// where that patch is larger than the fill's detail resolves, the sample
/// the rasterizer takes is one of many features the pixel really covers,
/// and which one it lands on changes with every camera step, so the far
/// range of a tilted view flickers. The fill shader measures the footprint
/// per pixel (the screen derivatives of the ground position along the
/// longer axis, in the source tile's units) and blends the fill toward the
/// style's far tone over the band below, so neighbouring fills converge on
/// one colour where they could not be told apart anyway. CPU mirror of
/// `tileFootprintFadeAmount` in TileShading.h.
enum GroundFootprintFade {
    /// Footprint, in tile units per pixel, at which the fade begins. A tile
    /// at its native scale is 8 units per point (4096 units over 512
    /// points), and the tiles are simplified with a half-pixel tolerance
    /// (8 units), so up to about three times that the fills still resolve
    /// features of a few pixels.
    static let startUnits: Float = 24
    /// Footprint at which the fade is complete: a pixel covering a 96-unit
    /// patch (1/43 of the tile's side) sees several land cover blobs at
    /// once.
    static let endUnits: Float = 96

    /// The fade amount for a footprint of `unitsPerPixel` tile units.
    static func amount(unitsPerPixel: Float) -> Float {
        let t = min(max((unitsPerPixel - startUnits) / (endUnits - startUnits), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
