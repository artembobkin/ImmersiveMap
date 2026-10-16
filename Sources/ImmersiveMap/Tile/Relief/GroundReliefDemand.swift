// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The terrain a frame needs, nearest first: what the frame asks the
/// store for once (`GroundReliefStore.request(tiles:)`), as it asks for
/// its map tiles. By the relief's detail (`GroundReliefTerrainZooms`):
///
/// - Cinematic, the two maps alone: the near map's two by two tiles
///   around the point the camera looks at, then the far map's
///   (`GroundReliefSettings.cinematicNearZoom`, `cinematicFarZoom`). Every
///   read of the frame takes the finest of them over its tile, and the
///   camera and the frame's datum read the near map.
/// - Otherwise, first the camera's map around the point it looks at
///   (`GroundReliefTerrainZooms.cameraZoom`), which the frame's datum and
///   the camera's terrain follow read, then every terrain tile a draw of
///   the frame reads, by its distance from that point:
///   - the ground of a placed tile at the finest ring it stands in
///     (`FlatMapSurfaceDrawer`, the labels), and at each ring
///     (`RasterTileRenderSubsystem`),
///   - the square a placement marks (`PlacementStencilRenderSubsystem`),
///   - the buildings of a building placement (`BuildingReliefLifts`).
///
///   Each read takes the terrain of
///   `GroundReliefTerrainZooms.terrainTile(for:targetZoom:)`, so each
///   finds its own tile in, not a coarser stand-in, once it lands.
enum GroundReliefDemand {
    static func tiles(groundPlacements: [PlaceTile],
                      buildingPlacements: [PlaceTile],
                      centerWorldMercator: SIMD2<Double>,
                      zooms: GroundReliefTerrainZooms) -> [Tile] {
        if zooms.detail == .cinematic {
            var result: [Tile] = []
            var seen: Set<Tile> = []
            for zoom in [zooms.cinematicNearZoom, zooms.cinematicFarZoom] {
                for tile in block(around: centerWorldMercator, zoom: zoom) where seen.insert(tile).inserted {
                    result.append(tile)
                }
            }
            return result
        }

        var result: [Tile] = []
        var seen: Set<Tile> = []

        // The camera's map: the tile under the point looked at, then the
        // eight around it, which the eye's ground falls in at a tilt.
        let cameraZoom = max(0, zooms.cameraZoom)
        let count = 1 << cameraZoom
        let column = Int((wrapped(centerWorldMercator.x) * Double(count)).rounded(.down))
        let row = Int((min(max(centerWorldMercator.y, 0), 1) * Double(count)).rounded(.down))
        let ring: [(Int, Int)] = [(0, 0), (-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, -1), (-1, 1), (1, 1)]
        for (dx, dy) in ring {
            let y = row + dy
            guard y >= 0, y < count else { continue }
            let x = ((column + dx) % count + count) % count
            let tile = Tile(x: x, y: y, z: cameraZoom)
            if seen.insert(tile).inserted {
                result.append(tile)
            }
        }

        // What the draws read, by distance.
        var distanceByTile: [Tile: Double] = [:]
        func want(_ tile: Tile, worldWrap: Int8) {
            let tilesCount = Double(1 << tile.z)
            let middle = SIMD2<Double>((Double(tile.x) + 0.5) / tilesCount + Double(worldWrap),
                                       (Double(tile.y) + 0.5) / tilesCount)
            let distance = simd_length(middle - centerWorldMercator)
            distanceByTile[tile] = min(distanceByTile[tile] ?? .infinity, distance)
        }
        var finestRingBySource: [VisibleTile: Int] = [:]
        for placement in groundPlacements {
            let source = VisibleTile(tile: placement.metalTile.tile, worldWrap: placement.placeIn.worldWrap)
            finestRingBySource[source] = max(finestRingBySource[source] ?? placement.slot.z, placement.slot.z)
            want(zooms.terrainTile(for: placement.metalTile.tile, targetZoom: placement.slot.z),
                 worldWrap: placement.placeIn.worldWrap)
            want(zooms.terrainTile(for: placement.placeIn.tile, targetZoom: placement.slot.z),
                 worldWrap: placement.placeIn.worldWrap)
        }
        for (source, ring) in finestRingBySource {
            want(zooms.terrainTile(for: source.tile, targetZoom: ring), worldWrap: source.worldWrap)
        }
        for placement in buildingPlacements {
            want(zooms.terrainTile(for: placement.metalTile.tile, targetZoom: placement.placeIn.z),
                 worldWrap: placement.placeIn.worldWrap)
        }
        for (tile, _) in distanceByTile.sorted(by: { $0.value < $1.value }) where seen.insert(tile).inserted {
            result.append(tile)
        }
        return result
    }

    /// The two by two tiles of `zoom` around a point, the point's own
    /// first, then those toward the nearer edges: the block's edge is at
    /// least half a tile from the point, wherever in its tile it lies.
    /// Nearest first. Fewer at the poles' rows and at zoom 0.
    static func block(around point: SIMD2<Double>, zoom: Int) -> [Tile] {
        let zoom = max(0, zoom)
        let count = 1 << zoom
        let x = wrapped(point.x) * Double(count)
        let y = min(max(point.y, 0), 1) * Double(count)
        let column = min(Int(x.rounded(.down)), count - 1)
        let row = min(Int(y.rounded(.down)), count - 1)
        let dx = x - Double(column) < 0.5 ? -1 : 1
        let dy = y - Double(row) < 0.5 ? -1 : 1
        var result: [Tile] = []
        for (ox, oy) in [(0, 0), (dx, 0), (0, dy), (dx, dy)] {
            let tileRow = row + oy
            guard tileRow >= 0, tileRow < count else { continue }
            let tile = Tile(x: ((column + ox) % count + count) % count, y: tileRow, z: zoom)
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
