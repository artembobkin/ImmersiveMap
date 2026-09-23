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

/// The Protomaps basemap's spelling of the road classes the theme names,
/// for a test that states a road by its class.
enum ProtomapsRoadSpelling {
    static func properties(forClass cls: String) -> [String: String] {
        switch cls {
        case "motorway": return ["kind": "highway", "kind_detail": "motorway"]
        case "trunk", "primary", "secondary", "tertiary": return ["kind": "major_road", "kind_detail": cls]
        case "minor": return ["kind": "minor_road", "kind_detail": "residential"]
        case "service": return ["kind": "minor_road", "kind_detail": "service"]
        case "path", "footway", "track": return ["kind": "path", "kind_detail": cls == "path" ? "footway" : cls]
        default: return ["kind": cls]
        }
    }

    static func values(forClass cls: String) -> [String: MvtValue] {
        properties(forClass: cls).mapValues { .string($0) }
    }
}

extension DetFeatureStyleData {
    /// A style input whose facts the Protomaps basemap schema reads, the
    /// way the parser reads them for that style.
    init(layerName: String,
         properties: [String: MvtValue],
         tile: Tile,
         geometryType: MvtGeometryType = .unknown) {
        let facts = ProtomapsBasemapSchema().facts(layerName: layerName,
                                                    properties: properties,
                                                    tile: tile,
                                                    geometryType: geometryType)
        self.init(layerName: layerName,
                  properties: properties,
                  tile: tile,
                  facts: facts,
                  geometryType: geometryType)
    }
}

extension ProtomapsBasemapDefaultMapStyle {
    /// The rules applied to a parser-side input, the way the parser applies
    /// them: through the public context.
    func makeStyle(data: DetFeatureStyleData) -> FeatureStyle {
        makeStyle(for: ImmersiveMapFeatureStyleContext(styleID: styleID, data: data))
    }
}
