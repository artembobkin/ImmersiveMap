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
/// with a name in several languages or a house number.
///
/// One question, asked per feature. What the parser decides per layer it
/// derives from the answers: every layer whose features are roads is a
/// road layer, and the road layers of a tile (the roads and the measured
/// streetscape shipped as a second layer) merge into one before they are
/// read, so a surface clips the ribbons that enter it whichever layer
/// either came from.
///
/// The engine's geometry work reads the facts and nothing else: which
/// draw phase a road takes, which surface owns which ribbon, where a
/// street stitches, what rises as a building, which spelling of a name
/// the map's language shows. The style reads the same facts next to the
/// properties and answers only with how the feature looks. Neither the
/// engine nor the style reads a tag by name to learn what a feature is.
///
/// The `Schema` folder: this protocol, the facts (`ImmersiveMapFeatureFacts`,
/// one case per kind of thing, carrying `ImmersiveMapRoadFacts`,
/// `ImmersiveMapBuildingExtrusion` or `ImmersiveMapLabelFacts`), the typed
/// property accessors, and the built-in reading of the hosted tiles in
/// `Default/`. No drawing, no colours, no Metal, no parsing.
public protocol ImmersiveMapTileSchema: Sendable {
    /// Folded into the prepared-tile cache identity: any change to the
    /// reading must change it, or the map keeps drawing from tiles prepared
    /// under the old reading.
    var cacheFingerprint: UInt32 { get }
    /// What the feature is. `.none` for a feature that is none of the
    /// things the facts describe: a ground fill, a border, a river.
    func read(_ feature: ImmersiveMapFeature) -> ImmersiveMapFeatureFacts
}
