// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt

extension ImmersiveMapTileSchema {
    /// The reading of one feature stated as a test states it: a layer, its
    /// properties, a tile.
    func facts(layerName: String,
               properties: [String: MvtValue],
               tile: Tile,
               geometryType: MvtGeometryType = .unknown) -> ImmersiveMapFeatureFacts {
        read(ImmersiveMapFeature(layerName: layerName, tile: tile, geometryType: geometryType, properties: properties))
    }
}

extension DetFeatureStyleData {
    /// A style input whose facts the hosted tiles' schema reads, the way
    /// the parser reads them for the built-in style. `isTunnelRoof` states
    /// the one fact the engine adds itself.
    init(layerName: String,
         properties: [String: MvtValue],
         tile: Tile,
         streetscapeEnabled: Bool = true,
         geometryType: MvtGeometryType = .unknown,
         isTunnelRoof: Bool = false) {
        var facts = ImmersiveMapTilesSchema().facts(layerName: layerName,
                                                    properties: properties,
                                                    tile: tile,
                                                    geometryType: geometryType)
        if isTunnelRoof, case .road(var road) = facts {
            road.isTunnelRoof = true
            facts = .road(road)
        }
        self.init(layerName: layerName,
                  properties: properties,
                  tile: tile,
                  facts: facts,
                  streetscapeEnabled: streetscapeEnabled,
                  geometryType: geometryType)
    }
}
