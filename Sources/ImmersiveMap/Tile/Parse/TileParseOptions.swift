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
    /// extrudes, so its merged blocks are neither tessellated nor uploaded.
    /// The placement side decides the number (`BuildingCoveragePlanner`).
    var buildingMinimumSourceZoom: Int
    /// The tile feature ids of the building outlines the landmarks replace,
    /// each with the first tile zoom it is replaced at: in a tile of that
    /// zoom or deeper, such an outline and every building part standing
    /// inside it are not extruded. Resolved from the landmarks by the schema.
    var replacedBuildingIDs: [UInt64: Int]

    init(labelsEnabled: Bool,
         addTestBorders: Bool,
         buildingMinimumSourceZoom: Int,
         replacedBuildingIDs: [UInt64: Int] = [:]) {
        self.labelsEnabled = labelsEnabled
        self.addTestBorders = addTestBorders
        self.buildingMinimumSourceZoom = buildingMinimumSourceZoom
        self.replacedBuildingIDs = replacedBuildingIDs
    }

    /// The one place the Parse layer reads the settings tree: the caller
    /// hands the parser the settings it holds, and this picks out what a
    /// parse depends on. The schema turns the landmarks' OSM outlines into
    /// tile feature ids. Without one, nothing is replaced.
    init(settings: ImmersiveMapSettings, schema: (any ImmersiveMapTileSchema)? = nil) {
        self.init(labelsEnabled: settings.labels.isEnabled,
                  addTestBorders: settings.tiles.parsing.addTestBorders,
                  buildingMinimumSourceZoom: BuildingCoveragePlanner.minimumSourceZoom,
                  replacedBuildingIDs: Self.replacedBuildingIDs(settings: settings, schema: schema))
    }

    private static func replacedBuildingIDs(settings: ImmersiveMapSettings,
                                            schema: (any ImmersiveMapTileSchema)?) -> [UInt64: Int] {
        let maximumTileZoom = settings.tiles.coverage.maximumZoomLevel
        var ids: [UInt64: Int] = [:]
        for landmark in settings.landmarks {
            guard let id = schema?.tileFeatureID(of: landmark.replacedBuilding) else { continue }
            let zoom = landmark.effectiveMinimumZoom(maximumTileZoom: maximumTileZoom)
            // Two landmarks on one building: the earlier zoom wins.
            ids[id] = min(ids[id] ?? zoom, zoom)
        }
        return ids
    }

    /// The replaced buildings as prepared-tile identity: zero when there are
    /// none, so a map without landmarks keeps the namespace it always had.
    var replacedBuildingsFingerprint: UInt64 {
        guard replacedBuildingIDs.isEmpty == false else { return 0 }
        var hasher = StableFNV1aHasher()
        for (id, zoom) in replacedBuildingIDs.sorted(by: { $0.key < $1.key }) {
            hasher.combine(id)
            hasher.combine(UInt64(zoom))
        }
        return hasher.finalize()
    }
}
