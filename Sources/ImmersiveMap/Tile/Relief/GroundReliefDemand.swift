// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The terrain a frame needs, nearest first: what the frame asks the
/// store for once (`GroundReliefStore.request(tiles:)`), as it asks for
/// its map tiles, and what the store keeps. First the camera's map around
/// the point it looks at (`GroundReliefTerrainZooms.cameraZoom`), which
/// the camera's terrain follow reads. Then the terrain of every target,
/// by its distance from that point: the ring's terrain over the target's
/// tile (`terrainSource`, the one the planner binds the tile to when both
/// are in, `TilePlacementPlanner`) and the one it displaces by, demanded
/// with the tile so they load side by side. Then the terrain the
/// placements shown rise by (`PlaceTile.terrain`, `displacement`), in
/// already, kept for as long as they stand. Last, the terrain the planner
/// wanted and found out (`also`): a stand-in it could not place for want
/// of its terrain, an ancestor's own tile that no target asks for.
/// Nothing else: a terrain no target asks for and no placement rises by
/// is released with the next demand.
///
/// A frame past the relief's zooms, collapsed into the plane, asks for
/// the terrain the relief would read when it rises back, no finer: its
/// targets stand for their ancestors at `maximumTargetZoom`, the tile
/// zoom of the collapse (`GroundReliefFrameState.collapseTileZoom`). The
/// street zooms' own tiles are nothing the relief ever reads, and most
/// of them the source has not got.
enum GroundReliefDemand {
    static func tiles(targets: [VisibleTile],
                      shown: [PlaceTile],
                      also: [Tile] = [],
                      centerWorldMercator: SIMD2<Double>,
                      zooms: GroundReliefTerrainZooms,
                      maximumTargetZoom: Int = .max,
                      terrainSource: (Tile, Int) -> (terrain: Tile, displacement: Tile)) -> [Tile] {
        var result: [Tile] = []
        var seen: Set<Tile> = []
        func want(_ tile: Tile) {
            if seen.insert(tile).inserted {
                result.append(tile)
            }
        }

        // The camera's map: the tile under the point looked at, then the
        // eight around it, which the eye's ground falls in at a tilt.
        ring(around: centerWorldMercator, zoom: zooms.cameraZoom).forEach(want)

        // The targets' terrain, by the target's distance from the point
        // looked at.
        var distanceByTile: [Tile: Double] = [:]
        var capped: Set<VisibleTile> = []
        for deep in targets {
            var target = deep
            if deep.z > maximumTargetZoom, let ancestor = deep.tile.findParentTile(atZoom: max(maximumTargetZoom, 0)) {
                target = VisibleTile(tile: ancestor, worldWrap: deep.worldWrap)
            }
            guard capped.insert(target).inserted else { continue }
            let sources = terrainSource(target.tile, target.z)
            let tilesCount = Double(1 << target.z)
            let middle = SIMD2<Double>((Double(target.x) + 0.5) / tilesCount + Double(target.worldWrap),
                                       (Double(target.y) + 0.5) / tilesCount)
            let distance = simd_length(middle - centerWorldMercator)
            for source in [sources.displacement, sources.terrain] {
                distanceByTile[source] = min(distanceByTile[source] ?? .infinity, distance)
            }
        }
        for (tile, _) in distanceByTile.sorted(by: { $0.value < $1.value }) {
            want(tile)
        }

        // What the placements shown rise by: in, and kept.
        for placement in shown {
            placement.displacement.map(want)
            placement.terrain.map(want)
        }
        // What the planner wanted and found out.
        also.forEach(want)
        return result
    }

    /// The three by three tiles of `zoom` around a point: the point's own
    /// first, then the four across its edges, then the four across its
    /// corners. The ring's edge is at least a whole tile from the point,
    /// wherever in its tile it lies. Fewer at the poles' rows and at the
    /// coarsest zooms, where the tiles wrap onto each other.
    static func ring(around point: SIMD2<Double>, zoom: Int) -> [Tile] {
        let zoom = max(0, zoom)
        let count = 1 << zoom
        let column = min(Int((wrapped(point.x) * Double(count)).rounded(.down)), count - 1)
        let row = min(Int((min(max(point.y, 0), 1) * Double(count)).rounded(.down)), count - 1)
        let offsets: [(Int, Int)] = [(0, 0), (-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1), (-1, 1), (1, 1)]
        var result: [Tile] = []
        for (dx, dy) in offsets {
            let y = row + dy
            guard y >= 0, y < count else { continue }
            let tile = Tile(x: ((column + dx) % count + count) % count, y: y, z: zoom)
            if result.contains(tile) == false {
                result.append(tile)
            }
        }
        return result
    }

    private static func wrapped(_ x: Double) -> Double {
        let fraction = x - x.rounded(.down)
        return fraction < 0 ? fraction + 1 : fraction
    }
}
