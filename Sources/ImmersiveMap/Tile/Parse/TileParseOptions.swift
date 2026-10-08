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
    /// The tile zoom the ground fills are flattened from, nil for never,
    /// and the grid they keep to (`GroundFlattening`,
    /// `TileSettings.GroundFlatteningSettings`).
    var groundFlatteningFromTileZoom: Int?
    var groundFlatteningGrid: Int

    static let groundFlatteningGridRange = 1 ... 256

    init(labelsEnabled: Bool,
         addTestBorders: Bool,
         buildingMinimumSourceZoom: Int,
         groundFlatteningFromTileZoom: Int? = nil,
         groundFlatteningGrid: Int = 16) {
        self.labelsEnabled = labelsEnabled
        self.addTestBorders = addTestBorders
        self.buildingMinimumSourceZoom = buildingMinimumSourceZoom
        self.groundFlatteningFromTileZoom = groundFlatteningFromTileZoom
        self.groundFlatteningGrid = min(max(groundFlatteningGrid, Self.groundFlatteningGridRange.lowerBound),
                                        Self.groundFlatteningGridRange.upperBound)
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
                  groundFlatteningFromTileZoom: settings.tiles.groundFlattening.fromTileZoom,
                  groundFlatteningGrid: settings.tiles.groundFlattening.grid)
    }
}
