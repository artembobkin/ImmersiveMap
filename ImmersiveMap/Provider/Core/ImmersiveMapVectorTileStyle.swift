// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt
import simd

public struct ImmersiveMapFeatureProperties {
    private let values: [String: MvtValue]

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

public struct ImmersiveMapFeatureStyleContext {
    public let providerID: String
    public let layerName: String
    public let tileZoom: Int
    public let tileX: Int
    public let tileY: Int
    public let geometry: ImmersiveMapFeatureGeometry
    public let properties: ImmersiveMapFeatureProperties
}

public struct ImmersiveMapLabelTextStyle: Equatable {
    public var fillColor: SIMD3<Float>
    public var strokeColor: SIMD3<Float>
    /// Halo width as a fraction of the em, so it tracks the text size.
    public var haloEm: Float
    /// Em size in layout points, not device pixels: the engine multiplies by the
    /// display's pixels-per-point at render time, so one value reads at the same
    /// physical size on a 2x desktop display and a 3x phone. Sizes below
    /// `11` are raised to it, the floor for type that is meant to be read.
    public var sizePoints: Float
    public var weight: LabelFontWeight

    public init(fillColor: SIMD3<Float>,
                strokeColor: SIMD3<Float>,
                haloEm: Float,
                sizePoints: Float,
                weight: LabelFontWeight) {
        self.fillColor = fillColor
        self.strokeColor = strokeColor
        self.haloEm = haloEm
        self.sizePoints = sizePoints
        self.weight = weight
    }
}

public enum ImmersiveMapFeatureStyle: Equatable {
    case hidden
    case polygon(color: SIMD4<Float>)
    /// A line of a width in tile units. `road` is what the feature is as a
    /// road (where it sits, which street it is a piece of), read by the
    /// style from the tile: `ImmersiveMapRoadFacts.openStreetMap(_:)` for
    /// an OpenStreetMap-derived schema, `.ground` for a line that is not a
    /// road or whose schema says nothing about it.
    case line(color: SIMD4<Float>, width: Float, road: ImmersiveMapRoadFacts = .ground)
    /// A line whose width is stated in on-screen points and held there at
    /// every zoom: the drawing mode the built-in style uses for country
    /// borders and for the overview road skeleton. The stroke is opaque from
    /// the first frame it is visible, ends in butt caps with plain joins, and
    /// an optional dash pattern is stated in points too, so it reads as
    /// dashes at every zoom. Suited to symbolic lines (borders, networks over
    /// a country view) whose weight is a design decision rather than a width
    /// on the ground; `line(color:width:)` stays the world-locked line whose
    /// width lives in tile units. Areal geometry a source ships under a line
    /// style is not filled: only the outlines draw.
    case pointLockedLine(color: SIMD4<Float>,
                         widthPoints: Float,
                         dashLengthPoints: Float = 0,
                         dashGapPoints: Float = 0,
                         road: ImmersiveMapRoadFacts = .ground)
    /// A building. What the feature is as a building (its height, its base,
    /// the building it belongs to, its roof) is the style's reading of the
    /// tile's tags: `ImmersiveMapBuildingExtrusion.openStreetMap(_:)` for
    /// an OpenStreetMap-derived schema, or the fields stated from another
    /// schema's tags. `heightScale`, `anchorZoom` and `fallbackHeight` say
    /// how metres become tile units and what a building without a height
    /// gets.
    case extrudedPolygon(color: SIMD4<Float>,
                         building: ImmersiveMapBuildingExtrusion,
                         heightScale: Float = 1.0,
                         anchorZoom: Int = 16,
                         fallbackHeight: Float = 0)
    case pointLabel(ImmersiveMapLabelTextStyle)
    case roadLabel(color: SIMD4<Float>,
                   width: Float,
                   textStyle: ImmersiveMapLabelTextStyle,
                   road: ImmersiveMapRoadFacts = .ground)
}

public protocol ImmersiveMapVectorTileStyle: Sendable {
    var cacheFingerprint: UInt32 { get }
    var baseColors: ImmersiveMapSettings.StyleSettings.BaseColors? { get }
    /// The layers whose line features are roads. From the zoom
    /// `StyleSettings.flatSeparateRoadRenderingMinimumZoom` names, a road
    /// layer draws on the separate-road path: seamless ribbons with the
    /// casing under the fill, sorted by structure and class, where the
    /// lines' `ImmersiveMapRoadFacts` decide the order and the stitching.
    /// Every other layer's lines draw as plain ground geometry. The default
    /// names the OpenMapTiles and Mapbox Streets road layers.
    var roadLayerNames: Set<String> { get }
    /// The layer of a measured streetscape (carriageway surfaces and the
    /// paint on them) that the tile source ships as a second archive
    /// (`TileSettings.StreetscapeSettings`), folded into the first road
    /// layer of a tile before the style sees either. Nil for a source that
    /// ships none.
    var streetscapeLayerName: String? { get }

    func makeStyle(for feature: ImmersiveMapFeatureStyleContext) -> ImmersiveMapFeatureStyle
}

public extension ImmersiveMapVectorTileStyle {
    var baseColors: ImmersiveMapSettings.StyleSettings.BaseColors? {
        nil
    }

    var roadLayerNames: Set<String> {
        ["transportation", "road"]
    }

    var streetscapeLayerName: String? {
        "streetscape"
    }
}

public struct BasicVectorTileStyle: ImmersiveMapVectorTileStyle {
    public var cacheFingerprint: UInt32
    public var fallbackColor: SIMD4<Float>

    public init(cacheFingerprint: UInt32 = 1,
                fallbackColor: SIMD4<Float> = SIMD4<Float>(1.0, 0.0, 0.0, 1.0)) {
        self.cacheFingerprint = cacheFingerprint
        self.fallbackColor = fallbackColor
    }

    public func makeStyle(for feature: ImmersiveMapFeatureStyleContext) -> ImmersiveMapFeatureStyle {
        .polygon(color: fallbackColor)
    }
}
