// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The ring rules' grid measure read off the sphere: how many rings of
/// target tiles lie between the look-at tile and a tile of any zoom. The
/// count is the plane's (`FlatRingRuleCoverage`: ring 0 the look-at tile
/// alone, ring 1 the three by three around it), with the two things the
/// sphere's grid does that the plane's does not. The columns close on
/// themselves at the antimeridian, so a column's distance is the shorter
/// way around, where the plane reaches into the next world copy. The rows
/// end at the poles, so a ring that runs off the last row is cut there.
enum GlobeRingMath {
    /// The target zoom's tile under the point the camera looks at, from the
    /// frame's fractional centre (`TileCulling.makeCenter`), which the
    /// globe's pan brings to the sphere's front point.
    static func lookAtTile(center: Center, targetZoom: Int) -> (x: Int, y: Int) {
        let tilesCount = 1 << max(targetZoom, 0)
        let clamp = { (value: Double) in min(max(Int(value.rounded(.down)), 0), tilesCount - 1) }
        return (clamp(center.tileX), clamp(center.tileY))
    }

    /// The rings of the nearest and the farthest target tile under `tile`,
    /// a tile at or above the target zoom.
    static func ringRange(of tile: Tile, targetZoom: Int, lookAt: (x: Int, y: Int)) -> ClosedRange<Int> {
        let shift = max(targetZoom - tile.z, 0)
        let tilesCount = 1 << max(targetZoom, 0)
        let span = 1 << shift
        let firstColumn = tile.x << shift
        let firstRow = tile.y << shift
        let rows = axisRange(first: firstRow, count: span, lookAt: lookAt.y)
        let columns = wrappedAxisRange(first: firstColumn, count: span, lookAt: lookAt.x, tilesCount: tilesCount)
        return max(rows.lowerBound, columns.lowerBound) ... max(rows.upperBound, columns.upperBound)
    }

    /// The distances from `lookAt` to the nearest and the farthest of
    /// `count` cells starting at `first`, on an axis with ends.
    static func axisRange(first: Int, count: Int, lookAt: Int) -> ClosedRange<Int> {
        let last = first + count - 1
        let nearest = lookAt < first ? first - lookAt : (lookAt > last ? lookAt - last : 0)
        return nearest ... max(abs(lookAt - first), abs(lookAt - last))
    }

    /// The same on an axis of `tilesCount` cells that closes on itself: a
    /// cell's distance is the shorter way around.
    static func wrappedAxisRange(first: Int, count: Int, lookAt: Int, tilesCount: Int) -> ClosedRange<Int> {
        guard count < tilesCount else {
            return 0 ... tilesCount / 2
        }
        // The look-at cell's offset past the block's first cell, going up
        // the axis. Inside the block it is under `count`.
        let offset = ((lookAt - first) % tilesCount + tilesCount) % tilesCount
        if offset < count {
            // The block never reaches half way around: it is a power of two
            // cells of a power of two axis, under the whole of it.
            return 0 ... max(offset, count - 1 - offset)
        }
        // Outside: going up the axis the block's cells are `nearestUp` to
        // `offset` steps behind the look-at cell, and a cell that many
        // steps behind is the shorter of that and the rest of the way
        // around.
        let nearestUp = offset - (count - 1)
        let nearest = min(nearestUp, tilesCount - offset)
        // The farthest is the cell nearest the antipode: half way around
        // when the antipode is inside the block, otherwise the block's end
        // on the antipode's side.
        let half = tilesCount / 2
        let farthest: Int
        if nearestUp <= half, half <= offset {
            farthest = half
        } else if offset < half {
            farthest = offset
        } else {
            farthest = tilesCount - nearestUp
        }
        return nearest ... farthest
    }
}
