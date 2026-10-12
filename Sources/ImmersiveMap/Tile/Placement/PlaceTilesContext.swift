// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

struct PlaceTilesContext {
    /// Logical tile layout for flat/extruded geometry rendering:
    /// carries GPU tile payload and placement target tile.
    let tilePlacements: [PlaceTile]
    
    init(tilePlacements: [PlaceTile]) {
        self.tilePlacements = tilePlacements
    }

    /// The finest target each source is placed in, by the source's tile:
    /// the ring whose terrain the source is raised by
    /// (`GroundReliefStore.terrainZoom(forTargetZoom:)`). A source placed
    /// in its own slot and as a stand-in reads the finer ring's.
    func targetZoomBySource() -> [Tile: Int] {
        var zooms: [Tile: Int] = [:]
        for placement in tilePlacements {
            let tile = placement.metalTile.tile
            zooms[tile] = max(zooms[tile] ?? 0, placement.placeIn.z)
        }
        return zooms
    }

    nonisolated(unsafe) static let empty = PlaceTilesContext(tilePlacements: [])
}
