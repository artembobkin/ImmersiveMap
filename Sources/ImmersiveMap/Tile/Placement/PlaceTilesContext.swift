// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

struct PlaceTilesContext {
    /// Logical tile layout for flat/extruded geometry rendering:
    /// carries GPU tile payload and placement target tile.
    let tilePlacements: [PlaceTile]
    
    init(tilePlacements: [PlaceTile]) {
        self.tilePlacements = tilePlacements
    }

    /// The terrain each source's grid rises by, by the source's tile: the
    /// finest of its placements' (`PlaceTile.displacement`), the heights
    /// what stands on the ground is placed at. A source placed in its own
    /// slot and as a stand-in rises by one terrain wherever it draws.
    func displacementBySource() -> [Tile: Tile] {
        var terrains: [Tile: Tile] = [:]
        for placement in tilePlacements {
            guard let terrain = placement.displacement else { continue }
            let tile = placement.metalTile.tile
            if terrain.z > (terrains[tile]?.z ?? -1) {
                terrains[tile] = terrain
            }
        }
        return terrains
    }

    nonisolated(unsafe) static let empty = PlaceTilesContext(tilePlacements: [])
}
