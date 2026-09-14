// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt
import simd

/// Everything the runtime derives from the configured map style: the
/// schema reading, the style itself and the base colors. The tile source
/// contributes nothing here; it is only a URL the loader fetches bytes
/// from.
///
/// This is the parser's view of the reading and the style: it asks the
/// schema what a feature is, builds the public
/// `ImmersiveMapFeatureStyleContext` from the feature and its facts, asks
/// the style how it draws, and adds what the engine decides on its own
/// (the debug frame, the cache identity the settings contribute). Every
/// style goes through here, the built-in one included.
///
/// The `Style` folder: the public style API (`ImmersiveMapMapStyle`,
/// `ImmersiveMapVectorTileStyle`, `FeatureStyle`, the building and road
/// readings), this runtime, and the built-in style in `Default/`.
/// Everything about interpreting a tile's
/// bytes lives here; nothing about fetching them does. No Metal, no
/// parsing, no networking.
struct MapStyleRuntime {
    let schema: any ImmersiveMapTileSchema
    let style: any ImmersiveMapVectorTileStyle
    let mapBaseColors: ImmersiveMapBaseColors
    /// The style's identity, the namespace its label identities are minted
    /// in.
    let styleID: String
    private let settings: ImmersiveMapSettings.StyleSettings

    init(settings: ImmersiveMapSettings) {
        self.init(mapStyle: settings.mapStyle, settings: settings)
    }

    /// `style` and `schema` replace the map style's own, which is how a
    /// test runs the parser against a style or a reading of its own.
    init(mapStyle: AnyImmersiveMapMapStyle,
         settings: ImmersiveMapSettings,
         style: (any ImmersiveMapVectorTileStyle)? = nil,
         schema: (any ImmersiveMapTileSchema)? = nil) {
        let style = style ?? mapStyle.vectorTileStyle
        self.schema = schema ?? mapStyle.schema
        self.style = style
        self.styleID = style.styleID
        self.mapBaseColors = ImmersiveMapBaseColors(settings: style.baseColors ?? settings.style.baseColors)
        self.settings = settings.style
    }

    /// The style's part of the prepared-tile cache identity: the reading's
    /// and the style's own fingerprints and the settings' style revision.
    var preparedTileStyleRevision: UInt32 {
        schema.cacheFingerprint &* 31 &+ style.cacheFingerprint &+ settings.preparedTileStyleRevision
    }

    var roadLayerNames: Set<String> {
        schema.roadLayerNames
    }

    var streetscapeLayerName: String? {
        schema.streetscapeLayerName
    }

    /// What a feature is, as the schema reading says.
    func readFacts(layerName: String,
                   properties: [String: MvtValue],
                   tile: Tile,
                   geometryType: MvtGeometryType) -> ImmersiveMapFeatureFacts {
        schema.read(ImmersiveMapFeature(layerName: layerName,
                                        tile: tile,
                                        geometryType: geometryType,
                                        properties: properties))
    }

    func makeStyle(data: DetFeatureStyleData) -> FeatureStyle {
        style.makeStyle(for: ImmersiveMapFeatureStyleContext(styleID: styleID, data: data))
    }

    func backgroundStyle(tile: Tile) -> FeatureStyle {
        style.backgroundStyle(tileZoom: tile.z)
    }

    func waterNameStyle(_ kind: WaterNameKind, tile: Tile) -> FeatureStyle? {
        style.waterNameStyle(kind, tileZoom: tile.z)
    }

    /// The one-unit frame around a tile the parser draws when the settings
    /// ask for the debug borders: the engine's, in the settings' fallback
    /// colour, whatever the style.
    func debugBorderStyle() -> FeatureStyle {
        FeatureStyle(key: 0,
                     color: settings.fallbackFeatureColor,
                     lineGeometry: LineGeometryStyle(lineWidth: 100))
    }
}
