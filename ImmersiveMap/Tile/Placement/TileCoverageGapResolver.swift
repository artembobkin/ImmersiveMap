// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// Resolves which parts of a target slot no placement paints, so the renderer
/// can fill exactly those parts with blank map-colored tiles.
///
/// Everything here leans on the quadtree property of tile space: two tiles are
/// either nested or disjoint, never partially overlapping, so regions are
/// plain `Tile` values and subtraction is a descent into children.
enum TileCoverageGapResolver {
    /// The area a placement actually paints on the surface.
    ///
    /// The geometry is drawn for the `placeIn` slot, and the fragment stage
    /// discards outside the source tile's content, so the painted area is the
    /// intersection of the two: the deeper of a nested pair, nothing when they
    /// are disjoint (such a placement paints no pixel at all).
    static func paintedRegion(placeIn: Tile, source: Tile) -> Tile? {
        if placeIn == source || source.covers(placeIn) {
            return placeIn
        }
        if placeIn.covers(source) {
            return source
        }
        return nil
    }

    /// Maximal sub-slots of `target` that no painted region covers, or
    /// `[target]` itself when nothing touches it. Painted regions elsewhere on
    /// the map are ignored; a region covering the whole target ends the search.
    ///
    /// Termination: every recursion step increases the node's zoom, and a
    /// painted region at the node's own zoom or above covers it entirely, so
    /// the descent never goes deeper than the deepest painted region.
    static func uncoveredSlots(target: Tile, paintedRegions: [Tile]) -> [Tile] {
        var insideTarget: [Tile] = []
        for region in paintedRegions {
            if region == target || region.covers(target) {
                return []
            }
            if target.covers(region) {
                insideTarget.append(region)
            }
        }
        guard insideTarget.isEmpty == false else {
            return [target]
        }
        return subtract(node: target, paintedRegions: insideTarget)
    }

    /// `paintedRegions` are strict descendants of `node` on entry.
    private static func subtract(node: Tile, paintedRegions: [Tile]) -> [Tile] {
        var uncovered: [Tile] = []
        for child in children(of: node) {
            var childIsCovered = false
            var insideChild: [Tile] = []
            for region in paintedRegions {
                if region == child || region.covers(child) {
                    childIsCovered = true
                    break
                }
                if child.covers(region) {
                    insideChild.append(region)
                }
            }
            if childIsCovered {
                continue
            }
            if insideChild.isEmpty {
                uncovered.append(child)
            } else {
                uncovered.append(contentsOf: subtract(node: child, paintedRegions: insideChild))
            }
        }
        return uncovered
    }

    private static func children(of tile: Tile) -> [Tile] {
        let x = tile.x << 1
        let y = tile.y << 1
        let z = tile.z + 1
        return [Tile(x: x, y: y, z: z),
                Tile(x: x + 1, y: y, z: z),
                Tile(x: x, y: y + 1, z: z),
                Tile(x: x + 1, y: y + 1, z: z)]
    }
}
