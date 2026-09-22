// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt

/// The parser's input to a style for one feature: the feature as the tile
/// carries it, the facts the schema reading made of it, and the two things
/// the map adds. The public `ImmersiveMapFeatureStyleContext` is built from
/// it.
struct DetFeatureStyleData {
    let layerName: String
    let properties: [String: MvtValue]
    let tile: Tile
    /// What the feature is (`ImmersiveMapTileSchema.read`), with the one
    /// fact the engine adds itself: a surface found to be a tunnel's roof.
    var facts: ImmersiveMapFeatureFacts
    /// See `ImmersiveMapFeatureStyleContext.layerCarriesStreetscape`.
    var layerCarriesStreetscape: Bool = true
    /// The geometry the feature carries.
    var geometryType: MvtGeometryType = .unknown
    /// See `ImmersiveMapFeatureStyleContext.layerShipsMeasuredCrossings`.
    var layerShipsMeasuredCrossings: Bool = false

    init(layerName: String,
         properties: [String: MvtValue],
         tile: Tile,
         facts: ImmersiveMapFeatureFacts,
         layerCarriesStreetscape: Bool = true,
         geometryType: MvtGeometryType = .unknown,
         layerShipsMeasuredCrossings: Bool = false) {
        self.layerName = layerName
        self.properties = properties
        self.tile = tile
        self.facts = facts
        self.layerCarriesStreetscape = layerCarriesStreetscape
        self.geometryType = geometryType
        self.layerShipsMeasuredCrossings = layerShipsMeasuredCrossings
    }

    /// The same feature as the public context describes it, for a style
    /// written against the raw properties.
    init(_ context: ImmersiveMapFeatureStyleContext) {
        let geometryType: MvtGeometryType
        switch context.geometry {
        case .point: geometryType = .point
        case .line: geometryType = .linestring
        case .polygon: geometryType = .polygon
        case .unknown: geometryType = .unknown
        }
        self.init(layerName: context.layerName,
                  properties: context.properties.values,
                  tile: Tile(x: context.tileX, y: context.tileY, z: context.tileZoom),
                  facts: context.facts,
                  layerCarriesStreetscape: context.layerCarriesStreetscape,
                  geometryType: geometryType,
                  layerShipsMeasuredCrossings: context.layerShipsMeasuredCrossings)
    }
}
