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
    /// Whether the map draws the streetscape (`TileSettings.StreetscapeSettings`).
    /// A road style reads it to decide between the measured carriageway and
    /// a street map's stroke: with the streetscape on, a road is drawn at
    /// its real width so the carriageway surfaces and paint of the second
    /// archive sit flush on it; with it off, a road is a stroke whose width
    /// is the class's alone, like every street map, and nothing about the
    /// ground's true dimensions is drawn.
    var streetscapeEnabled: Bool = true
    /// The geometry the feature carries.
    var geometryType: MvtGeometryType = .unknown

    init(layerName: String,
         properties: [String: MvtValue],
         tile: Tile,
         facts: ImmersiveMapFeatureFacts,
         streetscapeEnabled: Bool = true,
         geometryType: MvtGeometryType = .unknown) {
        self.layerName = layerName
        self.properties = properties
        self.tile = tile
        self.facts = facts
        self.streetscapeEnabled = streetscapeEnabled
        self.geometryType = geometryType
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
                  streetscapeEnabled: context.streetscapeEnabled,
                  geometryType: geometryType)
    }
}
