// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The style side of the parse: given a feature, how it draws. The parser
/// asks this for every feature of every layer, and for the three things it
/// draws on its own (the background under a tile, the debug frame, the
/// water names of the coarse zooms), and reads nothing else about the tile.
protocol ImmersiveMapStyle {
    var preparedTileStyleRevision: UInt32 { get }
    /// The layers whose features are roads. From the zoom the settings
    /// name, a road layer takes the separate-road path: seamless ribbons
    /// with the casing under the fill, sorted by structure and class, cut
    /// by the carriageway surfaces, with the paint stopping at junctions.
    /// Every other layer's lines draw as ground geometry.
    var roadLayerNames: Set<String> { get }
    /// The layer of the measured streetscape (the carriageway surfaces and
    /// the paint on them), which the tile source ships as a second archive
    /// and the parser folds into the first road layer of a tile before it
    /// reads either. Nil for a schema that ships none.
    var streetscapeLayerName: String? { get }
    func getMapBaseColors() -> ImmersiveMapBaseColors
    func makeStyle(data: DetFeatureStyleData) -> FeatureStyle
    /// The full-tile quad the parser puts under every feature of a tile,
    /// which is what paints the land where the schema ships no land
    /// polygon. Asked per tile, since the colour may follow the zoom.
    func backgroundStyle(tile: Tile) -> FeatureStyle
    /// The one-unit frame around a tile the parser draws when the settings
    /// ask for the debug borders.
    func debugBorderStyle() -> FeatureStyle
    /// The style of a water name the parser adds itself at zooms 0 to 2,
    /// for a schema whose tiles carry the ocean and sea names unreliably.
    /// Nil adds none.
    func waterNameStyle(_ kind: WaterNameKind, tile: Tile) -> FeatureStyle?
}

/// The bodies of water the parser can name on its own at the coarse zooms.
enum WaterNameKind {
    case ocean
    case sea
}

extension ImmersiveMapStyle {
    /// The hosted tiles' road and streetscape layers, and `road`.
    var roadLayerNames: Set<String> {
        ["transportation", "road"]
    }

    var streetscapeLayerName: String? {
        "streetscape"
    }

    /// A style that leaves the tiles' own water names as the only ones.
    func waterNameStyle(_ kind: WaterNameKind, tile: Tile) -> FeatureStyle? {
        nil
    }
}
