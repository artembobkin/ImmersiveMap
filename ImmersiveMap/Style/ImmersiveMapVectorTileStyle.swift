// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt
import simd

/// Everything a style is told about one feature before it says how the
/// feature draws: the feature as the tile carries it, the facts the schema
/// reading made of it, and the two things the map adds.
public struct ImmersiveMapFeatureStyleContext {
    /// The style's identity, the namespace its label identities are minted
    /// in.
    public let styleID: String
    public let layerName: String
    public let tileZoom: Int
    public let tileX: Int
    public let tileY: Int
    public let geometry: ImmersiveMapFeatureGeometry
    public let properties: ImmersiveMapFeatureProperties
    /// What the feature is, as the schema reading says (`ImmersiveMapTileSchema`):
    /// a road in a tunnel, a carriageway surface, a building of some
    /// height. A style draws by these rather than by reading the tags
    /// again, and a fact the engine derived (a surface found to be a
    /// tunnel's roof) arrives here and nowhere else.
    public let facts: ImmersiveMapFeatureFacts
    /// Whether the map draws the measured streetscape
    /// (`TileSettings.StreetscapeSettings`). A road style reads it to decide
    /// between the measured carriageway and a street map's stroke: with the
    /// streetscape on, a road is drawn at its real width so the carriageway
    /// surfaces and paint of the second archive sit flush on it; with it
    /// off, a road is a stroke whose width is the class's alone.
    public let streetscapeEnabled: Bool

    init(styleID: String, data: DetFeatureStyleData) {
        self.styleID = styleID
        self.layerName = data.layerName
        self.tileZoom = data.tile.z
        self.tileX = data.tile.x
        self.tileY = data.tile.y
        switch data.geometryType {
        case .point: self.geometry = .point
        case .linestring: self.geometry = .line
        case .polygon: self.geometry = .polygon
        case .unknown: self.geometry = .unknown
        }
        self.properties = ImmersiveMapFeatureProperties(values: data.properties)
        self.facts = data.facts
        self.streetscapeEnabled = data.streetscapeEnabled
    }
}

/// The bodies of water the parser can name on its own at the coarse zooms.
public enum WaterNameKind: Sendable {
    case ocean
    case sea
}

/// A map style: given a feature and what it is, how it draws. Every style
/// the engine draws with goes through this protocol, the built-in one
/// included.
///
/// The parser asks the style for every feature of every layer. What a
/// feature is (a building of some height, a road in a tunnel, a piece of
/// some street) is the schema reading's answer (`ImmersiveMapTileSchema`),
/// handed to the style in the context's `facts`; the style answers only
/// with the look, a `FeatureStyle`: colours, widths, dashes, the passes a
/// road draws in, the text style and rank of a label. The factories on
/// `FeatureStyle` (`polygon`, `line`, `extrudedPolygon`, `pointLabel` and
/// the rest) cover the common drawing modes; the full value is there for a
/// style that needs every knob the built-in one has. The label text itself
/// is not the style's: the engine reads it in the map's language, from the
/// `name` fields and the schema's `labelTextKeys`.
public protocol ImmersiveMapVectorTileStyle: Sendable {
    /// Folded into the prepared-tile cache identity: any change to the
    /// rules or the palette must change it, or the map keeps drawing from
    /// tiles prepared by the old style.
    var cacheFingerprint: UInt32 { get }
    /// The colours of the parts of the map that are not features (the tile
    /// background, the globe backdrop, water and land cover on the sphere);
    /// nil takes the settings' base colours.
    var baseColors: ImmersiveMapSettings.StyleSettings.BaseColors? { get }
    /// The style's identity: the namespace its label identities are minted
    /// in, so two styles never share a label across tiles. The default is
    /// one shared namespace for styles that state none.
    var styleID: String { get }
    /// Whether a label keeps one identity across tiles by its feature id, so
    /// a feature that straddles a tile edge is one label with one fade.
    /// False identifies labels by tile, layer, text and anchor.
    var labelsUseFeatureIdentity: Bool { get }

    func makeStyle(for feature: ImmersiveMapFeatureStyleContext) -> FeatureStyle

    /// The full-tile quad the parser puts under every feature of a tile,
    /// which is what paints the land where the schema ships no land
    /// polygon. Asked per tile, since the colour may follow the zoom. The
    /// default is transparent, so the tile background colour shows.
    func backgroundStyle(tileZoom: Int) -> FeatureStyle

    /// The style of a water name the parser adds itself at zooms 0 to 2,
    /// for a schema whose tiles carry the ocean and sea names unreliably.
    /// Nil, the default, adds none.
    func waterNameStyle(_ kind: WaterNameKind, tileZoom: Int) -> FeatureStyle?
}

public extension ImmersiveMapVectorTileStyle {
    var baseColors: ImmersiveMapSettings.StyleSettings.BaseColors? {
        nil
    }

    var styleID: String {
        AnyImmersiveMapMapStyle.genericStyleID
    }

    var labelsUseFeatureIdentity: Bool {
        true
    }

    /// Transparent, under a key below the range a style normally uses.
    func backgroundStyle(tileZoom: Int) -> FeatureStyle {
        .fill(FillStyle(key: 1, color: SIMD4<Float>(0, 0, 0, 0), outlineAntialiasing: false))
    }

    func waterNameStyle(_ kind: WaterNameKind, tileZoom: Int) -> FeatureStyle? {
        nil
    }
}

/// One colour for everything: the placeholder a source starts with before
/// it has a style.
public struct BasicVectorTileStyle: ImmersiveMapVectorTileStyle {
    public var cacheFingerprint: UInt32
    public var fallbackColor: SIMD4<Float>

    public init(cacheFingerprint: UInt32 = 1,
                fallbackColor: SIMD4<Float> = SIMD4<Float>(1.0, 0.0, 0.0, 1.0)) {
        self.cacheFingerprint = cacheFingerprint
        self.fallbackColor = fallbackColor
    }

    public func makeStyle(for feature: ImmersiveMapFeatureStyleContext) -> FeatureStyle {
        .polygon(key: 2, color: fallbackColor)
    }
}
