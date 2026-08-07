// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

struct TileAtlasPlaceTilesPlanner {
    static func buildPlacements(baseTargets: [VisibleTile],
                                readyTilesBySource: [Tile: MetalTile?],
                                baseZoom: Int,
                                previousContext: TileAtlasPlaceTilesContext) -> TileAtlasPlaceTilesContext {
        let previousBaseContext = PlaceTilesContext(
            tilePlacements: previousContext.tilePlacements.map(\.placeTile)
        )
        let baseContext = TilePlacementPlanner.buildPlacements(targets: baseTargets,
                                                               readyTilesBySource: readyTilesBySource,
                                                               zoom: baseZoom,
                                                               previousContext: previousBaseContext)
        let basePlacements = baseContext.tilePlacements.map {
            TileAtlasPlaceTile(placeTile: $0)
        }

        return TileAtlasPlaceTilesContext(tilePlacements: basePlacements,
                                          uncoveredSlots: makeUncoveredSlots(targets: baseTargets,
                                                                             placements: baseContext.tilePlacements))
    }

    /// Targets are non-overlapping, so a painted region can only intersect the
    /// target it was placed for; matching every target against the full painted
    /// list is therefore exact, and grouping exists only to respect `loop`.
    private static func makeUncoveredSlots(targets: [VisibleTile],
                                           placements: [PlaceTile]) -> [Tile] {
        guard targets.isEmpty == false else {
            return []
        }

        var paintedRegionsByLoop: [Int8: [Tile]] = [:]
        for placement in placements {
            guard let region = TileCoverageGapResolver.paintedRegion(placeIn: placement.placeIn.tile,
                                                                     source: placement.metalTile.tile) else {
                continue
            }
            paintedRegionsByLoop[placement.placeIn.loop, default: []].append(region)
        }

        var uncoveredSlots: [Tile] = []
        for target in targets {
            let paintedRegions = paintedRegionsByLoop[target.loop] ?? []
            uncoveredSlots.append(contentsOf: TileCoverageGapResolver.uncoveredSlots(target: target.tile,
                                                                                     paintedRegions: paintedRegions))
        }
        uncoveredSlots.sort { ($0.z, $0.x, $0.y) < ($1.z, $1.x, $1.y) }
        return uncoveredSlots
    }
}
