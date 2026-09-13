// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt
import simd

final class GenericVectorTileStyle: ImmersiveMapStyle {
    private let styleID: String
    private let style: any ImmersiveMapVectorTileStyle
    private let mapBaseColors: ImmersiveMapBaseColors
    private let fallbackStyle: FeatureStyle

    init(styleID: String,
         style: any ImmersiveMapVectorTileStyle,
         settings: ImmersiveMapSettings.StyleSettings) {
        self.styleID = styleID
        self.style = style
        let baseColors = style.baseColors ?? settings.baseColors
        self.mapBaseColors = ImmersiveMapBaseColors(settings: baseColors)
        self.fallbackStyle = FeatureStyle(
            key: 0,
            color: settings.fallbackFeatureColor,
            parseGeometryStyleData: ParseGeometryStyleData(lineWidth: 100)
        )
    }

    var preparedTileStyleRevision: UInt32 {
        style.cacheFingerprint
    }

    var roadLayerNames: Set<String> {
        style.roadLayerNames
    }

    var streetscapeLayerName: String? {
        style.streetscapeLayerName
    }

    func getMapBaseColors() -> ImmersiveMapBaseColors {
        mapBaseColors
    }

    /// Transparent: the tile background colour of the style's base colours
    /// shows through. The key sits below the range the feature keys hash
    /// into.
    func backgroundStyle(tile: Tile) -> FeatureStyle {
        FeatureStyle(key: 1,
                     color: SIMD4<Float>(0, 0, 0, 0),
                     parseGeometryStyleData: ParseGeometryStyleData(lineWidth: 0))
    }

    func debugBorderStyle() -> FeatureStyle {
        fallbackStyle
    }

    func makeStyle(data: DetFeatureStyleData) -> FeatureStyle {
        let context = ImmersiveMapFeatureStyleContext(
            styleID: styleID,
            layerName: data.layerName,
            tileZoom: data.tile.z,
            tileX: data.tile.x,
            tileY: data.tile.y,
            geometry: Self.geometry(of: data.geometryType),
            properties: ImmersiveMapFeatureProperties(values: data.properties)
        )
        let publicStyle = style.makeStyle(for: context)
        let key = styleKey(layerName: data.layerName, style: publicStyle)
        var featureStyle = resolvedStyle(publicStyle, key: key)
        featureStyle.road = Self.road(of: publicStyle)
        featureStyle.drawsAsTunnel = featureStyle.road.structure == .tunnel
        return featureStyle
    }

    private static func geometry(of type: MvtGeometryType) -> ImmersiveMapFeatureGeometry {
        switch type {
        case .point: return .point
        case .linestring: return .line
        case .polygon: return .polygon
        case .unknown: return .unknown
        }
    }

    private static func road(of style: ImmersiveMapFeatureStyle) -> ImmersiveMapRoadFacts {
        switch style {
        case let .line(_, _, road), let .pointLockedLine(_, _, _, _, road), let .roadLabel(_, _, _, road):
            return road
        case .hidden, .polygon, .extrudedPolygon, .pointLabel:
            return .ground
        }
    }

    private func resolvedStyle(_ publicStyle: ImmersiveMapFeatureStyle, key: UInt8) -> FeatureStyle {
        switch publicStyle {
        case .hidden:
            return FeatureStyle(
                key: key,
                color: SIMD4<Float>(0, 0, 0, 0),
                parseGeometryStyleData: ParseGeometryStyleData(lineWidth: 0)
            )
        case .polygon(let color):
            return FeatureStyle(
                key: key,
                color: color,
                parseGeometryStyleData: ParseGeometryStyleData(lineWidth: 100),
                fillOutlineAntialiasing: true
            )
        case .line(let color, let width, _):
            return FeatureStyle(
                key: key,
                color: color,
                parseGeometryStyleData: ParseGeometryStyleData(lineWidth: Double(max(Float(0), width)))
            )
        case .pointLockedLine(let color, let widthPoints, let dashLengthPoints, let dashGapPoints, _):
            return FeatureStyle.pointLockedLine(
                key: key,
                color: color,
                widthPoints: max(0, widthPoints),
                dashLengthPoints: max(0, dashLengthPoints),
                dashGapPoints: max(0, dashGapPoints),
                suppressPolygonFill: true
            )
        case .extrudedPolygon(let color, let building, let heightScale, let anchorZoom, let fallbackHeight):
            return FeatureStyle(
                key: key,
                color: color,
                parseGeometryStyleData: ParseGeometryStyleData(lineWidth: 100),
                building: building,
                extrusionHeightScale: heightScale,
                extrusionAnchorZoom: anchorZoom,
                extrusionFallbackHeight: fallbackHeight
            )
        case .pointLabel(let textStyle):
            return FeatureStyle(
                key: key,
                color: SIMD4<Float>(0, 0, 0, 0),
                parseGeometryStyleData: ParseGeometryStyleData(lineWidth: 0),
                labelTextStyle: makeLabelTextStyle(key: Int(key), style: textStyle)
            )
        case .roadLabel(let color, let width, let textStyle, _):
            return FeatureStyle(
                key: key,
                color: color,
                parseGeometryStyleData: ParseGeometryStyleData(lineWidth: Double(max(Float(0), width))),
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
            haloEm: style.haloEm,
            sizePoints: LabelTypeScale.clamped(style.sizePoints),
            weight: style.weight
        )
    }

    private func styleKey(layerName: String, style: ImmersiveMapFeatureStyle) -> UInt8 {
        var hasher = StableFNV1aHasher()
        hasher.combine(styleID)
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
        case let .line(color, width, _):
            // A road's facts vary per feature and are not part of the
            // style's identity, here and in the two cases below.
            hasher.combine(2)
            combine(color, into: &hasher)
            hasher.combine(UInt64(width.bitPattern))
        case let .pointLockedLine(color, widthPoints, dashLengthPoints, dashGapPoints, _):
            hasher.combine(6)
            combine(color, into: &hasher)
            hasher.combine(UInt64(widthPoints.bitPattern))
            hasher.combine(UInt64(dashLengthPoints.bitPattern))
            hasher.combine(UInt64(dashGapPoints.bitPattern))
        case let .extrudedPolygon(color, _, heightScale, anchorZoom, fallbackHeight):
            // The building's own facts vary per feature and are not part of
            // the style's identity.
            hasher.combine(3)
            combine(color, into: &hasher)
            hasher.combine(UInt64(heightScale.bitPattern))
            hasher.combine(UInt64(bitPattern: Int64(anchorZoom)))
            hasher.combine(UInt64(fallbackHeight.bitPattern))
        case let .pointLabel(textStyle):
            hasher.combine(4)
            combine(textStyle, into: &hasher)
        case let .roadLabel(color, width, textStyle, _):
            hasher.combine(5)
            combine(color, into: &hasher)
            hasher.combine(UInt64(width.bitPattern))
            combine(textStyle, into: &hasher)
        }
    }

    private static func combine(_ textStyle: ImmersiveMapLabelTextStyle, into hasher: inout StableFNV1aHasher) {
        combine(textStyle.fillColor, into: &hasher)
        combine(textStyle.strokeColor, into: &hasher)
        hasher.combine(UInt64(textStyle.haloEm.bitPattern))
        hasher.combine(UInt64(textStyle.sizePoints.bitPattern))
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
