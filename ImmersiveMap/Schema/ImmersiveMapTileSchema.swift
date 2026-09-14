// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt

/// The geometry a feature carries.
public enum ImmersiveMapFeatureGeometry: Sendable {
    case point
    case line
    case polygon
    case unknown
}

/// One feature as the tile carries it: which layer, which tile, which
/// geometry kind, and its properties. What the schema reading is given.
public struct ImmersiveMapFeature {
    public let layerName: String
    public let tileZoom: Int
    public let tileX: Int
    public let tileY: Int
    public let geometry: ImmersiveMapFeatureGeometry
    public let properties: ImmersiveMapFeatureProperties

    init(layerName: String,
         tile: Tile,
         geometryType: MvtGeometryType,
         properties: [String: MvtValue]) {
        self.layerName = layerName
        self.tileZoom = tile.z
        self.tileX = tile.x
        self.tileY = tile.y
        switch geometryType {
        case .point: self.geometry = .point
        case .linestring: self.geometry = .line
        case .polygon: self.geometry = .polygon
        case .unknown: self.geometry = .unknown
        }
        self.properties = ImmersiveMapFeatureProperties(values: properties)
    }
}

/// The reading of a tile schema: what a feature is, in the engine's own
/// words. Every schema names things differently (a road in a tunnel is
/// `brunnel=tunnel` in one, `structure=tunnel` or `layer=-1` in another),
/// and this is the one place a schema's spelling is turned into facts: a
/// road with a structure, a layer and a street identity, a building with
/// its heights, a carriageway surface, a line of measured paint, a point
/// that names a body of water.
///
/// The engine's geometry work reads the facts and nothing else: which
/// draw phase a road takes, which surface owns which ribbon, where a
/// street stitches, what rises as a building. The style reads the same
/// facts next to the properties and answers only with how the feature
/// looks. Neither the engine nor the style reads a tag by name to learn
/// what a feature is.
///
/// The `Schema` folder: this protocol, the fact types (`ImmersiveMapFeatureFacts`,
/// `ImmersiveMapRoadFacts`, `ImmersiveMapBuildingExtrusion`), the typed
/// property accessors, and the built-in reading of the hosted tiles in
/// `Default/`. No drawing, no colours, no Metal, no parsing.
public protocol ImmersiveMapTileSchema: Sendable {
    /// Folded into the prepared-tile cache identity: any change to the
    /// reading must change it, or the map keeps drawing from tiles prepared
    /// under the old reading.
    var cacheFingerprint: UInt32 { get }
    /// The layers whose line features are roads. From the zoom
    /// `StyleSettings.flatSeparateRoadRenderingMinimumZoom` names, a road
    /// layer draws on the separate-road path: seamless ribbons with the
    /// casing under the fill, sorted by structure and class, where the
    /// lines' `ImmersiveMapRoadFacts` decide the order and the stitching.
    /// Every other layer's lines draw as plain ground geometry. The default
    /// names the hosted tiles' road layer, `transportation`, and `road`.
    var roadLayerNames: Set<String> { get }
    /// The layer of a measured streetscape (carriageway surfaces and the
    /// paint on them) that the tile source ships as a second archive
    /// (`TileSettings.StreetscapeSettings`), folded into the first road
    /// layer of a tile before it is read. Nil for a source that ships none.
    var streetscapeLayerName: String? { get }
    /// Properties that carry a label's text beyond the ones the map's
    /// language chain reads (`name`, `name_xx`, `name:xx`), tried after
    /// them. Empty by default.
    var labelTextKeys: [String] { get }
    /// Layers whose point features are house numbers: labelled with the
    /// number (`house_num`, then `houseNumberTextKeys`) rather than a name.
    var houseNumberLayers: Set<String> { get }
    var houseNumberTextKeys: [String] { get }

    /// What the feature is. `.none` for a feature that is none of the
    /// things the facts describe: a ground fill, a border, a river.
    func read(_ feature: ImmersiveMapFeature) -> ImmersiveMapFeatureFacts
}

public extension ImmersiveMapTileSchema {
    var roadLayerNames: Set<String> {
        ["transportation", "road"]
    }

    var streetscapeLayerName: String? {
        "streetscape"
    }

    var labelTextKeys: [String] {
        []
    }

    var houseNumberLayers: Set<String> {
        []
    }

    var houseNumberTextKeys: [String] {
        []
    }
}
