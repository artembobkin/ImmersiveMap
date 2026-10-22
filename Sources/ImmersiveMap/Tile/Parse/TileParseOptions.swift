// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// What the parser is told about the map it parses for: the settings it
/// reads, and nothing else. `TileMvtParser` takes this value instead of the
/// whole `ImmersiveMapSettings` tree, so what a parse depends on is listed
/// here in one place, and a test can state it directly.
///
/// Every field here is part of the prepared-tile identity
/// (`PreparedTileCacheIdentity`): a tile parsed under one value of it must
/// never be served to a map that wants another. Adding a field means adding
/// it there too. The label policy (language, fallback chain, the style's
/// name fields) is not here: it comes in as `TileLabelDecisions`.
struct TileParseOptions: Equatable {
    /// Whether point and road labels are resolved and baked. Off, point
    /// features are skipped whole and no road name is looked up.
    var labelsEnabled: Bool
    /// Debug: a one-unit frame around every tile.
    var addTestBorders: Bool
    /// The coarsest tile zoom that draws buildings: a coarser tile never
    /// extrudes, so its buildings are neither tessellated nor uploaded.
    /// The placement side decides the number, from the zoom the buildings
    /// draw from (`BuildingCoveragePlanner.minimumDrawZoom(settings:)`).
    var buildingMinimumSourceZoom: Int
    /// The tileset's deepest zoom, where every building is a feature of
    /// its own. A coarser tile ships its buildings merged: the features of
    /// one height and kind are one feature, by the id of one of them, so
    /// the parts rules that go by a feature's id (an outline with parts
    /// stays flat, an outline that repeats a part goes) would lay a whole
    /// group flat. There each polygon stands at its group's height, and
    /// which of an outline and its parts stands is left to their geometry
    /// (`BuildingExtrusionResolver`). Nil when every tile's buildings are
    /// taken as features of their own.
    var buildingDeepestSourceZoom: Int?
    /// The tile zoom the ground fills are flattened from, nil for never,
    /// and the grid they keep to (`GroundFlattening`,
    /// `TileSettings.GroundFlatteningSettings`).
    var groundFlatteningFromTileZoom: Int?
    var groundFlatteningGrid: Int
    /// The grid of a tile zoom, over `groundFlatteningGrid` for the zooms
    /// it names (`GroundFlatteningSettings.gridByTileZoom`).
    var groundFlatteningGridByTileZoom: [Int: Int]
    /// Whether the flattened ground rises by a heightmap
    /// (`TileSettings.GroundReliefSettings`): the roads and the lines of a
    /// flattened tile then take a vertex at every crossing of the
    /// flattening's grid, so they follow the relief as the ground does.
    var groundReliefEnabled: Bool
    /// The coarsest tile zoom that stands trees on its woods and parks,
    /// the buildings' (`TreeCoveragePlanner.minimumSourceZoom(settings:)`),
    /// nil with the trees off: a coarser tile places none.
    var treeMinimumSourceZoom: Int?
    /// The most trees a tile keeps (`TreeSettings.maximumPerTile`).
    var treeMaximumPerTile: Int

    static let groundFlatteningGridRange = 1 ... 256

    init(labelsEnabled: Bool,
         addTestBorders: Bool,
         buildingMinimumSourceZoom: Int,
         buildingDeepestSourceZoom: Int? = nil,
         groundFlatteningFromTileZoom: Int? = nil,
         groundFlatteningGrid: Int = 16,
         groundFlatteningGridByTileZoom: [Int: Int] = [:],
         groundReliefEnabled: Bool = false,
         treeMinimumSourceZoom: Int? = nil,
         treeMaximumPerTile: Int = 0) {
        self.labelsEnabled = labelsEnabled
        self.addTestBorders = addTestBorders
        self.buildingMinimumSourceZoom = buildingMinimumSourceZoom
        self.buildingDeepestSourceZoom = buildingDeepestSourceZoom
        self.treeMinimumSourceZoom = treeMinimumSourceZoom
        self.treeMaximumPerTile = max(treeMaximumPerTile, 0)
        self.groundFlatteningFromTileZoom = groundFlatteningFromTileZoom
        self.groundFlatteningGrid = min(max(groundFlatteningGrid, Self.groundFlatteningGridRange.lowerBound),
                                        Self.groundFlatteningGridRange.upperBound)
        self.groundFlatteningGridByTileZoom = groundFlatteningGridByTileZoom.mapValues {
            min(max($0, Self.groundFlatteningGridRange.lowerBound), Self.groundFlatteningGridRange.upperBound)
        }
        self.groundReliefEnabled = groundReliefEnabled
    }

    /// The grid a flattened tile of `tileZoom` keeps to.
    func groundFlatteningGrid(forTileZoom tileZoom: Int) -> Int {
        groundFlatteningGridByTileZoom[tileZoom] ?? groundFlatteningGrid
    }

    /// The grids by zoom as one string, for the prepared-tile identity:
    /// empty without overrides.
    var groundFlatteningGridByTileZoomKey: String {
        groundFlatteningGridByTileZoom.keys.sorted().map { "\($0)=\(groundFlatteningGridByTileZoom[$0]!)" }.joined(separator: ",")
    }

    /// The grid step, in tile units, the roads and the lines of a tile of
    /// `tileZoom` take a vertex at, nil where they keep their own vertices:
    /// the flattening's grid, where the tile is flattened and the ground
    /// rises by a heightmap.
    func reliefSubdivisionStep(tileZoom: Int) -> Float? {
        guard groundReliefEnabled, flattensGround(tileZoom: tileZoom) else { return nil }
        return Float(TileCoordinateSpace.tileExtentDouble) / Float(groundFlatteningGrid(forTileZoom: tileZoom))
    }

    /// Whether a tile of `tileZoom` carries its ground flattened.
    func flattensGround(tileZoom: Int) -> Bool {
        guard let groundFlatteningFromTileZoom else { return false }
        return tileZoom >= groundFlatteningFromTileZoom
    }

    /// The one place the Parse layer reads the settings tree: the caller
    /// hands the parser the settings it holds, and this picks out what a
    /// parse depends on. The models that stand in for buildings are not
    /// among it: a tile keeps every building and says where each one is
    /// (`TileBuildingRange`), and the frame leaves out the ones a model
    /// names.
    init(settings: ImmersiveMapSettings) {
        self.init(labelsEnabled: settings.labels.isEnabled,
                  addTestBorders: settings.tiles.parsing.addTestBorders,
                  buildingMinimumSourceZoom: BuildingCoveragePlanner.minimumDrawZoom(settings: settings),
                  buildingDeepestSourceZoom: settings.tiles.coverage.maximumZoomLevel,
                  groundFlatteningFromTileZoom: settings.tiles.resolvedGroundFlatteningFromTileZoom,
                  groundFlatteningGrid: settings.tiles.groundFlattening.grid,
                  groundFlatteningGridByTileZoom: settings.tiles.groundFlattening.gridByTileZoom,
                  groundReliefEnabled: settings.tiles.groundRelief.isEnabled,
                  treeMinimumSourceZoom: TreeCoveragePlanner.minimumSourceZoom(settings: settings),
                  treeMaximumPerTile: settings.scene.trees.maximumPerTile)
    }
}
