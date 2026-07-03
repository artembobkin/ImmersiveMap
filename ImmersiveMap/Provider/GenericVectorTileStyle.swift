// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import simd

final class GenericVectorTileStyle: ImmersiveMapStyle {
    private let providerID: String
    private let style: any ImmersiveMapVectorTileStyle
    private let mapBaseColors: ImmersiveMapBaseColors
    private let fallbackStyle: FeatureStyle

    init(providerID: String,
         style: any ImmersiveMapVectorTileStyle,
         settings: ImmersiveMapSettings.StyleSettings) {
        self.providerID = providerID
        self.style = style
        let baseColors = style.baseColors ?? settings.baseColors
        self.mapBaseColors = ImmersiveMapBaseColors(settings: baseColors)
        self.fallbackStyle = FeatureStyle(
            key: 0,
            color: settings.fallbackFeatureColor,
            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 100)
        )
    }

    var preparedTileStyleRevision: UInt32 {
        style.cacheFingerprint
    }

    func getMapBaseColors() -> ImmersiveMapBaseColors {
        mapBaseColors
    }

    func makeStyle(data: DetFeatureStyleData) -> FeatureStyle {
        let context = ImmersiveMapFeatureStyleContext(
            providerID: providerID,
            layerName: data.layerName,
            tileZoom: data.tile.z,
            tileX: data.tile.x,
            tileY: data.tile.y,
            properties: ImmersiveMapFeatureProperties(values: data.properties)
        )
        let publicStyle = style.makeStyle(for: context)
        let key = styleKey(layerName: data.layerName, style: publicStyle)

        switch publicStyle {
        case .hidden:
            return FeatureStyle(
                key: key,
                color: SIMD4<Float>(0, 0, 0, 0),
                parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0)
            )
        case .polygon(let color):
            return FeatureStyle(
                key: key,
                color: color,
                parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 100)
            )
        case .line(let color, let width):
            return FeatureStyle(
                key: key,
                color: color,
                parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: Double(max(Float(0), width)))
            )
        case .extrudedPolygon(let color, let heightScale, let anchorZoom, let fallbackHeight):
            return FeatureStyle(
                key: key,
                color: color,
                parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 100),
                usesExtrusion: true,
                extrusionHeightScale: heightScale,
                extrusionAnchorZoom: anchorZoom,
                extrusionFallbackHeight: fallbackHeight
            )
        case .pointLabel(let textStyle):
            return FeatureStyle(
                key: key,
                color: SIMD4<Float>(0, 0, 0, 0),
                parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0),
                labelTextStyle: makeLabelTextStyle(key: Int(key), style: textStyle)
            )
        case .roadLabel(let color, let width, let textStyle):
            return FeatureStyle(
                key: key,
                color: color,
                parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: Double(max(Float(0), width))),
                includeRoadLabelPath: true,
                roadLabelTextStyle: makeLabelTextStyle(key: Int(key), style: textStyle)
            )
        }
    }

    private func makeLabelTextStyle(key: Int, style: ImmersiveMapLabelTextStyle) -> LabelTextStyle {
        LabelTextStyle(
            key: key,
            fillColor: style.fillColor,
            strokeColor: style.strokeColor,
            strokeWidthPx: style.strokeWidthPx,
            sizePx: style.sizePx,
            weight: style.weight
        )
    }

    private func styleKey(layerName: String, style: ImmersiveMapFeatureStyle) -> UInt8 {
        var hasher = StableFNV1aHasher()
        hasher.combine(providerID)
        hasher.combine(layerName)
        Self.combine(style, into: &hasher)
        return UInt8(3 + (hasher.finalize() % 205))
    }

    private static func combine(_ style: ImmersiveMapFeatureStyle, into hasher: inout StableFNV1aHasher) {
        switch style {
        case .hidden:
            hasher.combine(0)
        case let .polygon(color):
            hasher.combine(1)
            combine(color, into: &hasher)
        case let .line(color, width):
            hasher.combine(2)
            combine(color, into: &hasher)
            hasher.combine(UInt64(width.bitPattern))
        case let .extrudedPolygon(color, heightScale, anchorZoom, fallbackHeight):
            hasher.combine(3)
            combine(color, into: &hasher)
            hasher.combine(UInt64(heightScale.bitPattern))
            hasher.combine(UInt64(bitPattern: Int64(anchorZoom)))
            hasher.combine(UInt64(fallbackHeight.bitPattern))
        case let .pointLabel(textStyle):
            hasher.combine(4)
            combine(textStyle, into: &hasher)
        case let .roadLabel(color, width, textStyle):
            hasher.combine(5)
            combine(color, into: &hasher)
            hasher.combine(UInt64(width.bitPattern))
            combine(textStyle, into: &hasher)
        }
    }

    private static func combine(_ textStyle: ImmersiveMapLabelTextStyle, into hasher: inout StableFNV1aHasher) {
        combine(textStyle.fillColor, into: &hasher)
        combine(textStyle.strokeColor, into: &hasher)
        hasher.combine(UInt64(textStyle.strokeWidthPx.bitPattern))
        hasher.combine(UInt64(textStyle.sizePx.bitPattern))
        hasher.combine(UInt64(textStyle.weight.rawValue))
    }

    private static func combine(_ color: SIMD4<Float>, into hasher: inout StableFNV1aHasher) {
        hasher.combine(UInt64(color.x.bitPattern))
        hasher.combine(UInt64(color.y.bitPattern))
        hasher.combine(UInt64(color.z.bitPattern))
        hasher.combine(UInt64(color.w.bitPattern))
    }

    private static func combine(_ color: SIMD3<Float>, into hasher: inout StableFNV1aHasher) {
        hasher.combine(UInt64(color.x.bitPattern))
        hasher.combine(UInt64(color.y.bitPattern))
        hasher.combine(UInt64(color.z.bitPattern))
    }
}
