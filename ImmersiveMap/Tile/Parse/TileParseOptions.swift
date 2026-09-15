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
    /// From this tile zoom up, the road layer takes the separate-road path:
    /// seamless ribbons with the casing under the fill, sorted by structure
    /// and class, instead of ground polygons.
    var flatSeparateRoadRenderingMinimumZoom: Int
    /// The coarsest tile zoom that draws buildings: a coarser tile never
    /// extrudes, so its merged blocks are neither tessellated nor uploaded.
    /// The placement side decides the number (`BuildingCoveragePlanner`).
    var buildingMinimumSourceZoom: Int

    init(labelsEnabled: Bool,
         addTestBorders: Bool,
         flatSeparateRoadRenderingMinimumZoom: Int,
         buildingMinimumSourceZoom: Int) {
        self.labelsEnabled = labelsEnabled
        self.addTestBorders = addTestBorders
        self.flatSeparateRoadRenderingMinimumZoom = flatSeparateRoadRenderingMinimumZoom
        self.buildingMinimumSourceZoom = buildingMinimumSourceZoom
    }

    /// The one place the Parse layer reads the settings tree: the caller
    /// hands the parser the settings it holds, and this picks out what a
    /// parse depends on.
    init(settings: ImmersiveMapSettings) {
        self.init(labelsEnabled: settings.labels.isEnabled,
                  addTestBorders: settings.tiles.parsing.addTestBorders,
                  flatSeparateRoadRenderingMinimumZoom: settings.style.flatSeparateRoadRenderingMinimumZoom,
                  buildingMinimumSourceZoom: BuildingCoveragePlanner.minimumSourceZoom)
    }
}
