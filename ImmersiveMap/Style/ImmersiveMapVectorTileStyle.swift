// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt
import simd

/// A feature's properties as the tile carries them, read through typed
/// accessors: a schema is loose about types (an id may be a number or its
/// digits, a height a number or "12 ft", a flag a bool or the word "yes").
public struct ImmersiveMapFeatureProperties {
    let values: [String: MvtValue]

    init(values: [String: MvtValue]) {
        self.values = values
    }

    /// The property as text: `nil` when the key is absent, and the empty
    /// string when the key is present with a non-string value (the reading
    /// this accessor has always given, kept so a style written against it
    /// keeps working).
    public func string(_ key: String) -> String? {
        guard let value = values[key] else {
            return nil
        }
        return value.stringValue ?? ""
    }

    public func double(_ key: String) -> Double? {
        guard let value = values[key] else {
            return nil
        }
        switch value {
        case .double(let number):
            return number
        case .float(let number):
            return Double(number)
        case .int(let number), .sint(let number):
            return Double(number)
        case .uint(let number):
            return Double(number)
        case .string(let text):
            return Double(text)
        case .bool, .absent:
            return nil
        }
    }

    public func integer(_ key: String) -> Int? {
        guard let value = values[key] else {
            return nil
        }
        switch value {
        case .int(let number), .sint(let number):
            return Int(number)
        case .uint(let number):
            return Int(number)
        case .double(let number):
            return Int(number)
        case .float(let number):
            return Int(number)
        case .string(let text):
            return Int(text)
        case .bool, .absent:
            return nil
        }
    }

    /// The property as a measure in metres: a number as it is, a string by
    /// its leading number (`"12"`, `"12.5 m"`, `"3;4"` reads 3), feet
    /// converted. Nil when the key is absent or carries no number.
    public func metres(_ key: String) -> Float? {
        values[key]?.metresValue
    }

    /// The property as an identifier: a non-negative integer, or a string
    /// that spells one.
    public func unsignedInteger(_ key: String) -> UInt64? {
        values[key]?.uint64Value
    }

    /// The property spelled as text, whatever its type: a string as it is, a
    /// number as its digits, a flag as `1` or `0`, and empty when the key is
    /// absent. For keys that make up an identity.
    public func text(_ key: String) -> String {
        switch values[key] {
        case .string(let text): return text
        case .int(let number), .sint(let number): return String(number)
        case .uint(let number): return String(number)
        case .double(let number): return String(number)
        case .float(let number): return String(number)
        case .bool(let flag): return flag ? "1" : "0"
        case .absent, nil: return ""
        }
    }

    public func bool(_ key: String) -> Bool? {
        guard let value = values[key] else {
            return nil
        }
        if case .bool(let flag) = value {
            return flag
        }
        if let integer = integer(key) {
            return integer != 0
        }
        if case .string(let text) = value {
            let normalized = text.lowercased()
            if normalized == "true" || normalized == "yes" || normalized == "1" {
                return true
            }
            if normalized == "false" || normalized == "no" || normalized == "0" {
                return false
            }
        }
        return nil
    }
}

/// The geometry a feature carries.
public enum ImmersiveMapFeatureGeometry: Sendable {
    case point
    case line
    case polygon
    case unknown
}

/// Everything a style is told about one feature before it says how the
/// feature draws.
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
    /// Whether the map draws the measured streetscape
    /// (`TileSettings.StreetscapeSettings`). A road style reads it to decide
    /// between the measured carriageway and a street map's stroke: with the
    /// streetscape on, a road is drawn at its real width so the carriageway
    /// surfaces and paint of the second archive sit flush on it; with it
    /// off, a road is a stroke whose width is the class's alone.
    public let streetscapeEnabled: Bool
    /// The feature is a carriageway surface the parser found to be the roof
    /// of a tunnel: the surface ships no tunnel tag of its own, only the
    /// tunnel's `layer`, and the style draws it the way the tunnel's
    /// centreline would have been drawn.
    public let isTunnelRoof: Bool

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
        self.streetscapeEnabled = data.streetscapeEnabled
        self.isTunnelRoof = data.isTunnelRoof
    }
}

/// The bodies of water the parser can name on its own at the coarse zooms.
public enum WaterNameKind: Sendable {
    case ocean
    case sea
}

/// A map style: given a feature, how it draws. Every style the engine
/// draws with goes through this protocol, the built-in one included.
///
/// The parser asks the style for every feature of every layer and reads
/// nothing about the tile itself: what a feature is (a building of some
/// height, a road in a tunnel, a piece of some street, a place of some
/// rank) is the style's reading of the schema, stated in the
/// `FeatureStyle` it returns. The factories on `FeatureStyle` (`polygon`,
/// `line`, `extrudedPolygon`, `pointLabel` and the rest) cover the common
/// drawing modes; the full value is there for a style that needs every
/// knob the built-in one has. The label text itself is not the style's:
/// the engine reads it in the map's language, from the `name` fields and
/// the style's `labelTextKeys`.
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
    /// Properties that carry a label's text beyond the ones the map's
    /// language chain reads (`name`, `name_xx`, `name:xx`), tried after
    /// them. Empty by default.
    var labelTextKeys: [String] { get }
    /// Layers whose point features are house numbers: labelled with the
    /// number (`house_num`, then `houseNumberTextKeys`) rather than a name.
    var houseNumberLayers: Set<String> { get }
    var houseNumberTextKeys: [String] { get }
    /// Whether a label keeps one identity across tiles by its feature id, so
    /// a feature that straddles a tile edge is one label with one fade.
    /// False identifies labels by tile, layer, text and anchor.
    var labelsUseFeatureIdentity: Bool { get }
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
    /// layer of a tile before the style sees either. Nil for a source that
    /// ships none.
    var streetscapeLayerName: String? { get }

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

    var labelTextKeys: [String] {
        []
    }

    var houseNumberLayers: Set<String> {
        []
    }

    var houseNumberTextKeys: [String] {
        []
    }

    var labelsUseFeatureIdentity: Bool {
        true
    }

    var roadLayerNames: Set<String> {
        ["transportation", "road"]
    }

    var streetscapeLayerName: String? {
        "streetscape"
    }

    /// Transparent, under a key below the range a style normally uses.
    func backgroundStyle(tileZoom: Int) -> FeatureStyle {
        FeatureStyle(key: 1,
                     color: SIMD4<Float>(0, 0, 0, 0),
                     lineGeometry: LineGeometryStyle(lineWidth: 0))
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
