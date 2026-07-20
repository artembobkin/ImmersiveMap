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

        return TileAtlasPlaceTilesContext(tilePlacements: basePlacements)
    }
}
