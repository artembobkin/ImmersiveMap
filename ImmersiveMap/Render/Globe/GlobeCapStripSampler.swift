// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The two polar caps of the globe.
enum GlobeCapPole: CaseIterable {
    case north
    case south
}

/// The CPU mirror of how the cap shader reads the edge strip
/// (`GlobeCapEdgeStrip`): one row of texels around the whole equator of
/// longitude, so a cap fragment finds the colour the tiles show at the rim
/// under it with one texture coordinate, its longitude. Kept in step with
/// `globeCapFragmentShader` in Globe.metal by `GlobeCapStripSamplerTests`.
enum GlobeCapStripSampler {
    /// Texels across the strip: one full turn of longitude. The same width
    /// as a tile's extent, so a tile at zoom z owns `4096 / 2^z` texels.
    static let width = 4096
    /// Every mip down to one texel, the mean of the whole rim.
    static let mipLevelCount = 13
    static let maximumLod: Float = 12
    /// The polar band of a tile the strip rasterizes, in tile units: the
    /// last rows before the Mercator edge, the ones the cap continues.
    static let bandUnits: Float = 8

    /// The strip coordinate of a cap vertex's longitude angle (the cap grid
    /// stores the angle the tile path derives as `lon + pi`, one turn from
    /// the antimeridian), wrapped into 0..1.
    static func u(theta: Float) -> Float {
        let turns = theta / (2 * Float.pi)
        return turns - floor(turns)
    }

    /// The mip level the rim samples at, from the screen derivative of the
    /// longitude angle: the strip advances `width / 2 pi` texels per radian.
    static func lod(radiansPerPixel: Float) -> Float {
        let texelsPerPixel = radiansPerPixel * Float(width) / (2 * Float.pi)
        return min(max(log2(max(texelsPerPixel, 1e-6)), 0), maximumLod)
    }

    /// The level whose texels each average one tile's share of the rim at
    /// this tile zoom: the colour the cap fades into at the pole. Read with
    /// linear filtering it is continuous across the wedges, unlike a mean
    /// taken per tile.
    static func poleMeanLod(tileZoom: Int) -> Float {
        min(max(maximumLod - Float(tileZoom), 0), maximumLod)
    }

    /// Whether a placement slot touches the pole this cap sits on.
    static func isPoleRow(_ tile: Tile, pole: GlobeCapPole) -> Bool {
        switch pole {
        case .north:
            return tile.y == 0
        case .south:
            return tile.y == (1 << tile.z) - 1
        }
    }
}
