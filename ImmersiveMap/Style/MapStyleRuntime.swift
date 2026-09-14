// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Everything the runtime derives from the configured map style: the style
/// itself and the base colors. The tile source contributes nothing here; it
/// is only a URL the loader fetches bytes from.
///
/// This is the parser's view of the style: it builds the public
/// `ImmersiveMapFeatureStyleContext` for a feature, asks the style, and adds
/// what the engine decides on its own (the debug frame, the cache identity
/// the settings contribute). Every style goes through here, the built-in
/// one included.
///
/// The `Style` folder: the public style API (`ImmersiveMapMapStyle`,
/// `ImmersiveMapVectorTileStyle`, `FeatureStyle`, the building and road
/// readings), this runtime, and the built-in style in `Default/`.
/// Everything about interpreting a tile's
/// bytes lives here; nothing about fetching them does. No Metal, no
/// parsing, no networking.
struct MapStyleRuntime {
    let style: any ImmersiveMapVectorTileStyle
    let mapBaseColors: ImmersiveMapBaseColors
    /// The style's identity, the namespace its label identities are minted
    /// in.
    let styleID: String
    private let settings: ImmersiveMapSettings.StyleSettings

    init(settings: ImmersiveMapSettings) {
        self.init(mapStyle: settings.mapStyle, settings: settings)
    }

    /// `style` replaces the map style's own vector tile style, which is
    /// how a test runs the parser against a style of its own.
    init(mapStyle: AnyImmersiveMapMapStyle,
         settings: ImmersiveMapSettings,
         style: (any ImmersiveMapVectorTileStyle)? = nil) {
        let style = style ?? mapStyle.vectorTileStyle
        self.style = style
        self.styleID = style.styleID
        self.mapBaseColors = ImmersiveMapBaseColors(settings: style.baseColors ?? settings.style.baseColors)
        self.settings = settings.style
    }

    /// The style's part of the prepared-tile cache identity: the style's
    /// own fingerprint and the settings' style revision.
    var preparedTileStyleRevision: UInt32 {
        style.cacheFingerprint &+ settings.preparedTileStyleRevision
    }

    var roadLayerNames: Set<String> {
        style.roadLayerNames
    }

    var streetscapeLayerName: String? {
        style.streetscapeLayerName
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
