// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Which terrain tiles the ground reads, by the relief's detail
/// (`GroundReliefSettings.detail`): the zoom a ring reads its terrain at,
/// the map the camera flies over, and the cinematic detail's two maps.
/// Made once from the settings and held by the store
/// (`GroundReliefStore.zooms`), and asked by every draw that reads the
/// terrain and by the frame's demand (`GroundReliefDemand`), so what is
/// drawn and what is loaded agree.
///
/// The terrain is the ring's, not the tile's: whatever stands in a ring's
/// slot, the tile itself or a stand-in while it loads, is raised by the
/// same terrain, so a tile landing changes the fills and never the
/// ground's shape, and the whole ring moves to the next terrain at once,
/// at the zoom crossing, as its tiles do. A terrain tile finer than the
/// ground tile cannot raise it (four terrain tiles under one ground tile),
/// so a coarser tile reads the terrain of its own address instead
/// (`terrainTile(for:targetZoom:)`).
struct GroundReliefTerrainZooms: Equatable, Sendable {
    typealias Detail = ImmersiveMapSettings.TileSettings.GroundReliefDetail

    /// The camera's map with every height, where the settings name none:
    /// Mapterhorn's deepest global zoom.
    static let defaultCameraZoom = 12

    let detail: Detail
    /// The flattening's grids as the tiles are parsed with them
    /// (`TileSettings.resolvedGroundFlattening`), which the grid's detail
    /// matches.
    let flattening: ImmersiveMapSettings.TileSettings.GroundFlatteningSettings
    /// The cinematic detail's near and far maps' zooms
    /// (`GroundReliefSettings.cinematicNearZoom`, `cinematicFarZoom`), the
    /// far one never finer than the near one.
    let cinematicNearZoom: Int
    let cinematicFarZoom: Int
    /// The zoom of the camera's map (`GroundReliefSettings.cameraTerrainZoom`),
    /// the detail's own where that is unset.
    let cameraZoom: Int

    /// `deepestTileZoom` is the tileset's deepest zoom
    /// (`CoverageSettings.maximumZoomLevel`), which with the relief's
    /// collapse bounds the tiles the relief is drawn on.
    init(relief: ImmersiveMapSettings.TileSettings.GroundReliefSettings,
         flattening: ImmersiveMapSettings.TileSettings.GroundFlatteningSettings,
         deepestTileZoom: Int) {
        self.detail = relief.detail
        self.flattening = flattening
        self.cinematicNearZoom = max(0, relief.cinematicNearZoom)
        self.cinematicFarZoom = min(max(0, relief.cinematicFarZoom), max(0, relief.cinematicNearZoom))
        if let cameraTerrainZoom = relief.cameraTerrainZoom {
            self.cameraZoom = max(0, cameraTerrainZoom)
            return
        }
        switch relief.detail {
        case .maximum:
            self.cameraZoom = Self.defaultCameraZoom
        case .matchingGrid:
            // The terrain of the deepest tiles the relief stands on: the
            // tileset's deepest, or the last zoom before the collapse.
            let collapse = min(relief.collapseZoom, Double(deepestTileZoom) + 1)
            let deepest = min(deepestTileZoom, max(0, Int(collapse.nextDown.rounded(.down))))
            self.cameraZoom = Self.matchingGridTerrainZoom(forTargetZoom: deepest, flattening: flattening)
        case .cinematic:
            self.cameraZoom = self.cinematicNearZoom
        }
    }

    /// The zoom a ring of `zoom` reads its terrain at: the ring's own with
    /// every height, the zoom whose tile gives a ground tile one height a
    /// cell of its grid with the grid's, and the near map's with the
    /// cinematic two maps, past which the reads fall to the far map
    /// (`GroundReliefStore.relief(for:terrainZoom:)` takes the finest
    /// terrain in over a tile).
    func terrainZoom(forTargetZoom zoom: Int) -> Int {
        switch detail {
        case .maximum:
            return max(zoom, 0)
        case .matchingGrid:
            return Self.matchingGridTerrainZoom(forTargetZoom: zoom, flattening: flattening)
        case .cinematic:
            return cinematicNearZoom
        }
    }

    /// The terrain tile a ground tile in a ring of `targetZoom` reads
    /// (`GroundReliefStore.relief(for:terrainZoom:)` without its
    /// stand-ins): the ring's terrain over the tile, or the tile's own
    /// address when that is coarser.
    func terrainTile(for tile: Tile, targetZoom: Int) -> Tile {
        tile.findParentTile(atZoom: max(min(terrainZoom(forTargetZoom: targetZoom), tile.z), 0)) ?? tile
    }

    /// The coarsest terrain zoom that still gives a ground tile of `zoom`
    /// a height at every vertex of its grid: a terrain tile of
    /// `GroundReliefStore.nominalTerrainTileSize` heights a side covers
    /// 2^d ground tiles a side d zooms finer, each with the size over 2^d
    /// heights, and the ground rises at its grid's vertices alone.
    static func matchingGridTerrainZoom(forTargetZoom zoom: Int,
                                        flattening: ImmersiveMapSettings.TileSettings.GroundFlatteningSettings) -> Int {
        let range = TileParseOptions.groundFlatteningGridRange
        let grid = min(max(flattening.grid(forTileZoom: zoom), range.lowerBound), range.upperBound)
        var drop = 0
        while GroundReliefStore.nominalTerrainTileSize >> (drop + 1) >= grid {
            drop += 1
        }
        return max(zoom - drop, 0)
    }
}
