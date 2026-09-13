// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt

struct DetFeatureStyleData {
    let layerName: String
    let properties: [String: MvtValue]
    let tile: Tile
    /// Whether the map draws the streetscape (`TileSettings.StreetscapeSettings`).
    /// A road style reads it to decide between the measured carriageway and
    /// a street map's stroke: with the streetscape on, a road is drawn at
    /// its real width so the carriageway surfaces and paint of the second
    /// archive sit flush on it; with it off, a road is a stroke whose width
    /// is the class's alone, like every street map, and nothing about the
    /// ground's true dimensions is drawn.
    var streetscapeEnabled: Bool = true
    /// The geometry the feature carries, so a style reads a road's stitching
    /// key for a line and not for the thousand polygons around it.
    var geometryType: MvtGeometryType = .unknown
    /// The feature is a carriageway surface the parser found to be the roof
    /// of a tunnel (`RoadTunnelSurfaceResolver`): the surface ships no
    /// tunnel tag of its own, only the tunnel's `layer`, and the style draws
    /// it the way the tunnel's centreline would have been drawn.
    var isTunnelRoof: Bool = false

    init(layerName: String,
         properties: [String: MvtValue],
         tile: Tile,
         streetscapeEnabled: Bool = true,
         geometryType: MvtGeometryType = .unknown,
         isTunnelRoof: Bool = false) {
        self.layerName = layerName
        self.properties = properties
        self.tile = tile
        self.streetscapeEnabled = streetscapeEnabled
        self.geometryType = geometryType
        self.isTunnelRoof = isTunnelRoof
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
                  streetscapeEnabled: context.streetscapeEnabled,
                  geometryType: geometryType,
                  isTunnelRoof: context.isTunnelRoof)
    }
}
