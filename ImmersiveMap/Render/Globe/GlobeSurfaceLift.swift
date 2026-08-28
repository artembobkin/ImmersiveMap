// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// How far the tile geometry drawn on the sphere is lifted off it, as a
/// fraction of the radius, per source tile zoom.
///
/// The placeholder grid under the geometry (Globe.metal, 60 rows linear in
/// latitude) and the tile triangles (Mercator-linear, split on the parser's
/// grid, see `GroundGeometrySubdivider`) are two different chord
/// approximations of the same sphere. Where the geometry's chord dips below
/// the grid's it would fail the depth test the grid wrote; lifted above the
/// larger of the two sags, with a margin, it passes everywhere. The geometry
/// never writes depth, so the lift changes nothing else, and the horizon
/// clip and the lighting read the unlifted position.
enum GlobeSurfaceLift {
    /// Floor for deep zooms, where both sags vanish: above the float depth
    /// resolution at the zooms the globe still shows (up to about 7).
    static let minimum: Float = 2e-5
    private static let margin: Float = 1.5

    static func factor(sourceTileZoom: Int) -> Float {
        let zoom = max(0, sourceTileZoom)
        return max(minimum, margin * max(polygonSag(tileZoom: zoom), gridSag(tileZoom: zoom)))
    }

    /// Chord sag of one subdivision step of a tile at this zoom: the step is
    /// a fraction of the tile, the tile a fraction of the equator.
    static func polygonSag(tileZoom: Int) -> Float {
        guard let step = GroundGeometrySubdivider.step(forTileZoom: tileZoom) else {
            return 0
        }
        let stepAngle = 2 * Float.pi * Float(step) / (4096 * Float(1 << tileZoom))
        return 1 - cos(stepAngle / 2)
    }

    /// Chord sag of one row of the placeholder grid: the tile's latitude span
    /// over its 60 rows. The equatorial tile at this zoom spans the most
    /// latitude, so it bounds every tile of the zoom.
    static func gridSag(tileZoom: Int) -> Float {
        let rows: Float = 60
        // The latitude span of the tile row that straddles the equator: from
        // the Mercator y of its northern edge (half a tile above the equator).
        let halfTileMercator = Float.pi / Float(1 << tileZoom)
        let edgeLatitude = 2 * atan(exp(halfTileMercator)) - Float.pi / 2
        let latitudeSpan = 2 * edgeLatitude
        return 1 - cos(latitudeSpan / rows / 2)
    }
}
