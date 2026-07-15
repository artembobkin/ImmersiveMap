// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

public struct ImmersiveMapFeatureProperties {
    private let values: [String: VectorTile_Tile.Value]

    init(values: [String: VectorTile_Tile.Value]) {
        self.values = values
    }

    public func string(_ key: String) -> String? {
        values[key]?.stringValue
    }

    public func double(_ key: String) -> Double? {
        guard let value = values[key] else {
            return nil
        }
        if value.hasDoubleValue {
            return value.doubleValue
        }
        if value.hasFloatValue {
            return Double(value.floatValue)
        }
        if value.hasIntValue {
            return Double(value.intValue)
        }
        if value.hasUintValue {
            return Double(value.uintValue)
        }
        if value.hasSintValue {
            return Double(value.sintValue)
        }
        if value.hasStringValue {
            return Double(value.stringValue)
        }
        return nil
    }

    public func integer(_ key: String) -> Int? {
        guard let value = values[key] else {
            return nil
        }
        if value.hasIntValue {
            return Int(value.intValue)
        }
        if value.hasUintValue {
            return Int(value.uintValue)
        }
        if value.hasSintValue {
            return Int(value.sintValue)
        }
        if value.hasDoubleValue {
            return Int(value.doubleValue)
        }
        if value.hasFloatValue {
            return Int(value.floatValue)
        }
        if value.hasStringValue {
            return Int(value.stringValue)
        }
        return nil
    }

    public func bool(_ key: String) -> Bool? {
        guard let value = values[key] else {
            return nil
        }
        if value.hasBoolValue {
            return value.boolValue
        }
        if let integer = integer(key) {
            return integer != 0
        }
        if value.hasStringValue {
            let normalized = value.stringValue.lowercased()
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

public struct ImmersiveMapFeatureStyleContext {
    public let providerID: String
    public let layerName: String
    public let tileZoom: Int
    public let tileX: Int
    public let tileY: Int
    public let properties: ImmersiveMapFeatureProperties
}

public struct ImmersiveMapLabelTextStyle: Equatable {
    public var fillColor: SIMD3<Float>
    public var strokeColor: SIMD3<Float>
    public var strokeWidthPx: Float
    public var sizePx: Float
    public var weight: LabelFontWeight

    public init(fillColor: SIMD3<Float>,
                strokeColor: SIMD3<Float>,
                strokeWidthPx: Float,
                sizePx: Float,
                weight: LabelFontWeight) {
        self.fillColor = fillColor
        self.strokeColor = strokeColor
        self.strokeWidthPx = strokeWidthPx
        self.sizePx = sizePx
        self.weight = weight
    }
}

public enum ImmersiveMapFeatureStyle: Equatable {
    case hidden
    case polygon(color: SIMD4<Float>)
    case line(color: SIMD4<Float>, width: Float)
    case extrudedPolygon(color: SIMD4<Float>,
                         heightScale: Float = 1.0,
                         anchorZoom: Int = 16,
                         fallbackHeight: Float = 0)
    case pointLabel(ImmersiveMapLabelTextStyle)
    case roadLabel(color: SIMD4<Float>,
                   width: Float,
                   textStyle: ImmersiveMapLabelTextStyle)
}

public protocol ImmersiveMapVectorTileStyle: Sendable {
    var cacheFingerprint: UInt32 { get }
    var baseColors: ImmersiveMapSettings.StyleSettings.BaseColors? { get }

    func makeStyle(for feature: ImmersiveMapFeatureStyleContext) -> ImmersiveMapFeatureStyle
}

public extension ImmersiveMapVectorTileStyle {
    var baseColors: ImmersiveMapSettings.StyleSettings.BaseColors? {
        nil
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
