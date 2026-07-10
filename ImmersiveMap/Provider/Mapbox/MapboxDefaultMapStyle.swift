// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit


class MapboxDefaultMapStyle: ImmersiveMapStyle {
    private let fallbackKey: UInt8 = 0
    private let labelKey: UInt8 = 2
    private let roadLowZoomFadeMask: Float = 2.0
    private let landuseLowZoomFadeMask: Float = 3.0
    private let zebraCrossingMinimumZoom: Int = 15
    private let onewayArrowKey: UInt8 = 209
    private let fallbackStyle: FeatureStyle
    private let configuration: MapboxDefaultMapStyleConfiguration
    private let mapBaseColors: ImmersiveMapBaseColors
    private let styleSettings: ImmersiveMapSettings.StyleSettings
    private let poiSpriteResolver = PoiSpriteResolver()

    init(configuration: MapboxDefaultMapStyleConfiguration = .mapboxDefault,
         settings: ImmersiveMapSettings.StyleSettings = ImmersiveMapSettings.default.style) {
        self.configuration = configuration
        self.styleSettings = settings
        self.mapBaseColors = ImmersiveMapBaseColors(settings: settings.baseColors)
        fallbackStyle = FeatureStyle(
            key: fallbackKey,
            color: settings.fallbackFeatureColor,
            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 100)
        )
    }
    
    func getMapBaseColors() -> ImmersiveMapBaseColors {
        return mapBaseColors
    }

    var preparedTileStyleRevision: UInt32 {
        styleSettings.preparedTileStyleRevision &+ configuration.cacheFingerprint
    }

    private var labelStyles: MapboxDefaultMapStyleConfiguration.LabelStyles { configuration.labels }
    private var layerStyles: MapboxDefaultMapStyleConfiguration.LayerStyles { configuration.layers }
    private var featureStyles: MapboxDefaultMapStyleConfiguration.FeatureStyles { configuration.features }

    private func makeLabelTextStyle(key: Int,
                                    appearance: MapboxDefaultMapStyleConfiguration.LabelAppearance,
                                    strokeWidthPx: Float? = nil,
                                    sizePx: Float) -> LabelTextStyle {
        LabelTextStyle(
            key: key,
            fillColor: appearance.fillColor,
            strokeColor: appearance.strokeColor,
            strokeWidthPx: strokeWidthPx ?? appearance.strokeWidthPx,
            sizePx: sizePx,
            weight: appearance.weight
        )
    }

    private func makeLabelTextStyle(layerName: String,
                                    classValue: String?,
                                    tileZoom: Int,
                                    properties: [String: VectorTile_Tile.Value]) -> LabelTextStyle? {
        let normalizedLayerName = layerName.lowercased()
        let isPoiLabel = normalizedLayerName == "poi_label"
        let isHouseNumber = normalizedLayerName == "housenum_label"
        let normalizedClassValue = classValue?.lowercased()
        let normalizedTypeValue = properties["type"]?.stringValue.lowercased()
        let isAirport = normalizedLayerName == "airport_label"
        let isNaturalFeature = normalizedLayerName == "natural_label"
            && isNaturalLabelClass(normalizedClassValue)
        let isContinent = normalizedLayerName == "natural_label"
            && (normalizedClassValue == "continent" || normalizedTypeValue == "continent")
        let isOcean = normalizedLayerName == "natural_label"
            && isOceanLabelClass(normalizedClassValue)
        let isSea = normalizedLayerName == "natural_label"
            && isSeaLabelClass(normalizedClassValue)
        let capitalLevel = capitalLevel(properties)
        let isNationalCapital = capitalLevel == 2
        let isSmallCity = normalizedTypeValue == "town"
            || normalizedTypeValue == "village"
            || normalizedTypeValue == "hamlet"
            || normalizedTypeValue == "isolated_dwelling"
        let isCity = normalizedTypeValue == "city"
            || (normalizedTypeValue == nil && normalizedClassValue == "settlement")
        let isDistrict = normalizedClassValue == "settlement_subdivision"
            || normalizedTypeValue == "suburb"
            || normalizedTypeValue == "quarter"
            || normalizedTypeValue == "neighborhood"
            || normalizedTypeValue == "neighbourhood"
            || normalizedTypeValue == "locality"
            || normalizedTypeValue == "borough"
            || normalizedTypeValue == "district"
        let isLandmark = isAirport
            || isNaturalFeature
            || isLandmarkClass(normalizedTypeValue)
            || isLandmarkClass(normalizedClassValue)

        if isContinent {
            return makeLabelTextStyle(
                key: 1,
                appearance: labelStyles.continent,
                sizePx: continentLabelSize(for: tileZoom)
            )
        }

        if isOcean {
            let size = oceanLabelSize(for: tileZoom)
            let appearance = labelStyles.water
            return makeLabelTextStyle(
                key: 3,
                appearance: appearance,
                strokeWidthPx: min(appearance.strokeWidthPx, waterLabelStrokeWidth(for: size)),
                sizePx: size
            )
        }

        if isSea {
            let size = seaLabelSize(for: tileZoom)
            let appearance = labelStyles.water
            return makeLabelTextStyle(
                key: 4,
                appearance: appearance,
                strokeWidthPx: min(appearance.strokeWidthPx, waterLabelStrokeWidth(for: size)),
                sizePx: size
            )
        }

        if isNationalCapital {
            return makeLabelTextStyle(
                key: 2,
                appearance: labelStyles.nationalCapital,
                sizePx: capitalSize(level: capitalLevel, tileZoom: tileZoom)
            )
        }

        if capitalLevel > 0 {
            let size = capitalSize(level: capitalLevel, tileZoom: tileZoom)
            return makeLabelTextStyle(
                key: 20 + min(capitalLevel, 9),
                appearance: labelStyles.capital,
                sizePx: size
            )
        }

        if isCity {
            return makeLabelTextStyle(
                key: 30,
                appearance: labelStyles.city,
                sizePx: cityLabelSize(for: tileZoom)
            )
        }

        if isSmallCity {
            return makeLabelTextStyle(
                key: 31,
                appearance: labelStyles.smallSettlement,
                sizePx: smallSettlementLabelSize(for: tileZoom)
            )
        }

        if isDistrict {
            return makeLabelTextStyle(
                key: 40,
                appearance: labelStyles.district,
                sizePx: districtLabelSize(for: tileZoom)
            )
        }

        if isHouseNumber {
            return makeLabelTextStyle(
                key: 43,
                appearance: labelStyles.houseNumber,
                sizePx: houseNumberLabelSize(for: tileZoom)
            )
        }

        if isPoiLabel {
            if isLandmark,
               poiSpriteResolver.resolve(attributes: properties, layerName: normalizedLayerName) == nil {
                return makeLandmarkLabelTextStyle(tileZoom: tileZoom)
            }
            return makePoiLabelTextStyle(tileZoom: tileZoom, properties: properties)
        }

        if isLandmark {
            return makeLandmarkLabelTextStyle(tileZoom: tileZoom)
        }

        return nil
    }

    private func makeRoadLabelTextStyle() -> LabelTextStyle {
        return makeLabelTextStyle(
            key: 80,
            appearance: labelStyles.road,
            sizePx: 36.0
        )
    }

    private func makeLandmarkLabelTextStyle(tileZoom: Int) -> LabelTextStyle {
        makeLabelTextStyle(
            key: 41,
            appearance: labelStyles.landmark,
            sizePx: landmarkLabelSize(for: tileZoom)
        )
    }

    private func makePoiLabelTextStyle(tileZoom: Int,
                                       properties: [String: VectorTile_Tile.Value]) -> LabelTextStyle {
        let appearance = poiLabelAppearance(properties: properties)
        return LabelTextStyle(
            key: appearance.key,
            fillColor: appearance.fillColor,
            strokeColor: labelStyles.poi.strokeColor,
            strokeWidthPx: labelStyles.poi.strokeWidthPx,
            sizePx: poiLabelSize(for: tileZoom),
            weight: labelStyles.poi.weight
        )
    }

    private func poiLabelAppearance(properties: [String: VectorTile_Tile.Value]) -> (key: Int, fillColor: SIMD3<Float>) {
        switch poiSpriteResolver.resolve(attributes: properties, layerName: "poi_label") {
        case .restaurant?:
            return (420, SIMD3<Float>(0.84, 0.42, 0.24))
        case .cafe?:
            return (421, SIMD3<Float>(0.72, 0.50, 0.30))
        case .bar?:
            return (422, SIMD3<Float>(0.69, 0.34, 0.41))
        case .park?:
            return (423, SIMD3<Float>(0.22, 0.56, 0.30))
        case .museum?:
            return (424, SIMD3<Float>(0.37, 0.45, 0.78))
        case .hospital?:
            return (425, SIMD3<Float>(0.84, 0.28, 0.30))
        case .school?:
            return (426, SIMD3<Float>(0.30, 0.49, 0.78))
        case .airport?:
            return (427, SIMD3<Float>(0.24, 0.57, 0.77))
        case .stadium?:
            return (428, SIMD3<Float>(0.12, 0.57, 0.53))
        case .hotel?:
            return (429, SIMD3<Float>(0.55, 0.40, 0.74))
        case .shopping?:
            return (430, SIMD3<Float>(0.80, 0.34, 0.64))
        case .gasStation?:
            return (431, SIMD3<Float>(0.21, 0.61, 0.72))
        case .pharmacy?:
            return (432, SIMD3<Float>(0.16, 0.63, 0.47))
        case .viewpoint?:
            return (433, SIMD3<Float>(0.70, 0.53, 0.22))
        case nil:
            return (42, labelStyles.poi.fillColor)
        }
    }

    private func makeRoadGeometryStyle(lineWidth: Double) -> TileMvtParser.ParseGeometryStyleData {
        TileMvtParser.ParseGeometryStyleData(lineWidth: lineWidth,
                                             lineCapRound: true,
                                             lineJoinRound: true)
    }

    private func makeDashedRoadGeometryStyle(lineWidth: Double,
                                             dashLength: Double,
                                             dashGap: Double) -> TileMvtParser.ParseGeometryStyleData {
        TileMvtParser.ParseGeometryStyleData(lineWidth: lineWidth,
                                             lineCapRound: true,
                                             lineJoinRound: false,
                                             dashLength: dashLength,
                                             dashGap: dashGap)
    }

    private func makeSquareDashedRoadGeometryStyle(lineWidth: Double,
                                                   dashLength: Double,
                                                   dashGap: Double) -> TileMvtParser.ParseGeometryStyleData {
        TileMvtParser.ParseGeometryStyleData(lineWidth: lineWidth,
                                             lineCapRound: false,
                                             lineJoinRound: false,
                                             dashLength: dashLength,
                                             dashGap: dashGap,
                                             dashResetsPerSegment: true)
    }

    private func makeRoadCasingColor(from fillColor: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4<Float>(max(fillColor.x - 0.22, 0.0),
                     max(fillColor.y - 0.22, 0.0),
                     max(fillColor.z - 0.22, 0.0),
                     fillColor.w)
    }

    private func makeBridgeShadowColor(from fillColor: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4<Float>(max(fillColor.x - 0.12, 0.0),
                     max(fillColor.y - 0.12, 0.0),
                     max(fillColor.z - 0.12, 0.0),
                     min(max(fillColor.w, 0.82), 0.9))
    }

    private func makeRoadDetailColor(from fillColor: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4<Float>(max(fillColor.x - 0.40, 0.0),
                     max(fillColor.y - 0.40, 0.0),
                     max(fillColor.z - 0.40, 0.0),
                     min(fillColor.w, 0.30))
    }

    private func isBridgeRoad(properties: [String: VectorTile_Tile.Value]) -> Bool {
        let structureValue = properties["structure"]?.stringValue.lowercased() ?? ""
        let brunnelValue = properties["brunnel"]?.stringValue.lowercased() ?? ""
        let locationValue = properties["location"]?.stringValue.lowercased() ?? ""
        let layerValue = properties["layer"].flatMap(parseIntValue) ?? 0

        if isTruthy(properties["bridge"]) {
            return true
        }

        return structureValue == "bridge"
            || brunnelValue == "bridge"
            || locationValue.contains("bridge")
            || locationValue.contains("elevated")
            || layerValue > 0
    }

    private func bridgeOverlayBaseKey(for style: FeatureStyle) -> UInt8? {
        switch style.key {
        case 172:
            return 40
        case 175:
            return 50
        case 176:
            return 60
        case 177:
            return 70
        case 178:
            return 10
        case 179:
            return 20
        case 180:
            return 30
        case 181:
            return 80
        case 182:
            return 90
        case 190:
            return 100
        case 191:
            return 110
        case 192:
            return 120
        case 193:
            return 130
        case 194:
            return 140
        case 195:
            return 150
        case 196:
            return 160
        case 199:
            return 170
        case 200, 202:
            return 180
        case 201, 203:
            return 190
        case 205:
            return 200
        default:
            return nil
        }
    }

    private func makeBridgeStyle(baseStyle: FeatureStyle) -> FeatureStyle {
        guard let baseKey = bridgeOverlayBaseKey(for: baseStyle) else {
            return baseStyle
        }

        let basePasses = baseStyle.resolvedLineRenderPasses.filter { $0.parseGeometryStyleData.lineWidth > 0 }
        guard basePasses.isEmpty == false else {
            return baseStyle
        }

        let maxLineWidth = basePasses.reduce(baseStyle.parseGeometryStyleData.lineWidth) { partial, pass in
            max(partial, pass.parseGeometryStyleData.lineWidth)
        }

        var bridgePasses: [LineRenderPass] = []
        bridgePasses.reserveCapacity(basePasses.count + 2)
        bridgePasses.append(
            LineRenderPass(
                key: baseKey,
                color: makeBridgeShadowColor(from: baseStyle.color),
                lowZoomFadeMask: baseStyle.lowZoomFadeMask,
                parseGeometryStyleData: makeRoadGeometryStyle(
                    lineWidth: maxLineWidth + max(2.0, maxLineWidth * 0.18)
                ),
                includeRoadLabelPath: false,
                placement: .bridgeOverlay,
                roadPassRole: .shadow
            )
        )

        var nextKey = baseKey + 1
        if basePasses.count == 1, basePasses[0].parseGeometryStyleData.usesDashPattern == false {
            bridgePasses.append(
                LineRenderPass(
                    key: nextKey,
                    color: makeRoadCasingColor(from: basePasses[0].color),
                    lowZoomFadeMask: basePasses[0].lowZoomFadeMask,
                    parseGeometryStyleData: makeRoadGeometryStyle(
                        lineWidth: basePasses[0].parseGeometryStyleData.lineWidth
                            + max(1.0, basePasses[0].parseGeometryStyleData.lineWidth * 0.1)
                    ),
                    includeRoadLabelPath: false,
                    placement: .bridgeOverlay,
                    roadPassRole: .casing
                )
            )
            nextKey += 1
        }

        for basePass in basePasses {
            bridgePasses.append(
                LineRenderPass(
                    key: nextKey,
                    color: basePass.color,
                    lowZoomFadeMask: basePass.lowZoomFadeMask,
                    parseGeometryStyleData: basePass.parseGeometryStyleData,
                    includeRoadLabelPath: basePass.includeRoadLabelPath,
                    placement: .bridgeOverlay,
                    roadPassRole: basePass.roadPassRole
                )
            )
            nextKey += 1
        }

        let rootPass = bridgePasses.last(where: { $0.includeRoadLabelPath }) ?? bridgePasses.last!
        return FeatureStyle(
            key: rootPass.key,
            color: rootPass.color,
            lowZoomFadeMask: rootPass.lowZoomFadeMask,
            parseGeometryStyleData: rootPass.parseGeometryStyleData,
            includeRoadLabelPath: rootPass.includeRoadLabelPath,
            linePlacement: .bridgeOverlay,
            lineRenderPasses: bridgePasses,
            roadClassPriority: baseStyle.roadClassPriority,
            roadLabelTextStyle: baseStyle.roadLabelTextStyle,
            roadDecorationKind: baseStyle.roadDecorationKind
        )
    }

    private func bridgeifyRoadStyleIfNeeded(_ style: FeatureStyle,
                                            properties: [String: VectorTile_Tile.Value],
                                            tileZoom: Int) -> FeatureStyle {
        guard style.key != fallbackKey,
              tileZoom >= 12,
              isBridgeRoad(properties: properties) else {
            return style
        }
        return makeBridgeStyle(baseStyle: style)
    }

    private func makeDualPassRoadStyle(fillKey: UInt8,
                                       casingKey: UInt8,
                                       fillColor: SIMD4<Float>,
                                       fillWidth: Double,
                                       roadClassPriority: Int,
                                       includeRoadLabelPath: Bool = true,
                                       roadLabelTextStyle: LabelTextStyle? = nil) -> FeatureStyle {
        let fillGeometryStyle = makeRoadGeometryStyle(lineWidth: fillWidth)
        let casingGeometryStyle = makeRoadGeometryStyle(lineWidth: fillWidth * 1.35)
        let casingColor = makeRoadCasingColor(from: fillColor)

        return FeatureStyle(
            key: fillKey,
            color: fillColor,
            lowZoomFadeMask: roadLowZoomFadeMask,
            parseGeometryStyleData: fillGeometryStyle,
            includeRoadLabelPath: includeRoadLabelPath,
            lineRenderPasses: [
                LineRenderPass(key: casingKey,
                               color: casingColor,
                               lowZoomFadeMask: roadLowZoomFadeMask,
                               parseGeometryStyleData: casingGeometryStyle,
                               includeRoadLabelPath: false,
                               roadPassRole: .casing),
                LineRenderPass(key: fillKey,
                               color: fillColor,
                               lowZoomFadeMask: roadLowZoomFadeMask,
                               parseGeometryStyleData: fillGeometryStyle,
                               includeRoadLabelPath: includeRoadLabelPath,
                               roadPassRole: .fill)
            ],
            roadClassPriority: roadClassPriority,
            roadLabelTextStyle: roadLabelTextStyle
        )
    }

    private func makeSinglePassRoadStyle(key: UInt8,
                                         fillColor: SIMD4<Float>,
                                         fillWidth: Double,
                                         roadClassPriority: Int,
                                         includeRoadLabelPath: Bool = false,
                                         roadLabelTextStyle: LabelTextStyle? = nil) -> FeatureStyle {
        FeatureStyle(
            key: key,
            color: fillColor,
            lowZoomFadeMask: roadLowZoomFadeMask,
            parseGeometryStyleData: makeRoadGeometryStyle(lineWidth: fillWidth),
            includeRoadLabelPath: includeRoadLabelPath,
            roadClassPriority: roadClassPriority,
            roadLabelTextStyle: roadLabelTextStyle
        )
    }

    private func makeOnewayArrowPass(fillColor: SIMD4<Float>,
                                     lineWidth: Double,
                                     placement: LinePlacement,
                                     lowZoomFadeMask: Float) -> LineRenderPass {
        LineRenderPass(
            key: onewayArrowKey,
            color: makeRoadDetailColor(from: fillColor),
            lowZoomFadeMask: lowZoomFadeMask,
            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: lineWidth),
            includeRoadLabelPath: false,
            placement: placement,
            roadPassRole: .detail
        )
    }

    private func shouldUseOnewayArrowDecoration(properties: [String: VectorTile_Tile.Value],
                                                normalizedRoadClass: String?,
                                                tileZoom: Int) -> Bool {
        guard tileZoom >= styleSettings.flatSeparateRoadRenderingMinimumZoom,
              isTruthy(properties["oneway"]),
              let normalizedRoadClass else {
            return false
        }

        switch normalizedRoadClass {
        case "motorway",
             "motorway_link",
             "trunk",
             "trunk_link",
             "primary",
             "primary_link",
             "secondary",
             "secondary_link",
             "tertiary",
             "tertiary_link",
             "major_road",
             "street",
             "highway",
             "minor",
             "service",
             "residential",
             "driveway",
             "parking_aisle",
             "alley",
             "living_street",
             "street_limited",
             "unclassified":
            return true
        default:
            return false
        }
    }

    private func decorateRoadStyleIfNeeded(_ style: FeatureStyle,
                                           properties: [String: VectorTile_Tile.Value],
                                           normalizedRoadClass: String?,
                                           tileZoom: Int) -> FeatureStyle {
        guard shouldUseOnewayArrowDecoration(properties: properties,
                                             normalizedRoadClass: normalizedRoadClass,
                                             tileZoom: tileZoom) else {
            return style
        }

        let basePasses = style.resolvedLineRenderPasses.filter { $0.parseGeometryStyleData.lineWidth > 0 }
        guard let fillPass = basePasses.last(where: { $0.roadPassRole == .fill }) ?? basePasses.last else {
            return style
        }

        var decoratedPasses = style.resolvedLineRenderPasses
        decoratedPasses.append(
            makeOnewayArrowPass(fillColor: fillPass.color,
                                lineWidth: fillPass.parseGeometryStyleData.lineWidth,
                                placement: style.linePlacement,
                                lowZoomFadeMask: style.lowZoomFadeMask)
        )

        return FeatureStyle(
            key: style.key,
            color: style.color,
            lowZoomFadeMask: style.lowZoomFadeMask,
            parseGeometryStyleData: style.parseGeometryStyleData,
            includeRoadLabelPath: style.includeRoadLabelPath,
            linePlacement: style.linePlacement,
            lineRenderPasses: decoratedPasses,
            roadClassPriority: style.roadClassPriority,
            usesExtrusion: style.usesExtrusion,
            extrusionHeightScale: style.extrusionHeightScale,
            extrusionAnchorZoom: style.extrusionAnchorZoom,
            extrusionFallbackHeight: style.extrusionFallbackHeight,
            labelTextStyle: style.labelTextStyle,
            roadLabelTextStyle: style.roadLabelTextStyle,
            roadDecorationKind: .onewayArrow
        )
    }

    private func makeRoadFillWidth(tileZoom: Int,
                                   baseWidth: Double,
                                   minWidthAt10: Double,
                                   minWidthAt12: Double,
                                   startZoom: Int = 16) -> Double {
        let factor = pow(2.0, Double(tileZoom - startZoom))
        let minWidth: Double
        if tileZoom <= 10 {
            minWidth = minWidthAt10
        } else if tileZoom <= 12 {
            minWidth = minWidthAt12
        } else {
            minWidth = 0
        }
        return max(baseWidth * factor, minWidth)
    }

    private func makeZebraCrossingStyle(tileZoom: Int) -> FeatureStyle {
        let crossingWidth = makeRoadFillWidth(tileZoom: tileZoom,
                                              baseWidth: 44.0,
                                              minWidthAt10: 6.0,
                                              minWidthAt12: 6.0)
        let geometryStyle = makeRoadGeometryStyle(lineWidth: crossingWidth)
        let zebraColor = SIMD4<Float>(1.0, 1.0, 1.0, 1.0)

        return FeatureStyle(
            key: 208,
            color: zebraColor,
            lowZoomFadeMask: roadLowZoomFadeMask,
            parseGeometryStyleData: geometryStyle,
            lineRenderPasses: [
                LineRenderPass(key: 208,
                               color: zebraColor,
                               lowZoomFadeMask: roadLowZoomFadeMask,
                               parseGeometryStyleData: geometryStyle,
                               includeRoadLabelPath: false,
                               roadPassRole: .overlay)
            ],
            roadClassPriority: 110,
            roadDecorationKind: .zebraCrossing
        )
    }

    private func makeStepsRoadStyle(tileZoom: Int,
                                    colors: [String: SIMD4<Float>]) -> FeatureStyle {
        let fillWidth = makeRoadFillWidth(tileZoom: tileZoom,
                                          baseWidth: 12.0,
                                          minWidthAt10: 2.0,
                                          minWidthAt12: 2.0)
        let stripeLength = max(2.0, fillWidth * 0.45)
        let stripeGap = max(2.0, fillWidth * 0.55)
        let baseColor = colors["road_steps_base"]!
        let stripeColor = colors["road_steps"]!
        let baseGeometryStyle = makeRoadGeometryStyle(lineWidth: fillWidth)
        let stripeGeometryStyle = makeSquareDashedRoadGeometryStyle(lineWidth: fillWidth,
                                                                    dashLength: stripeLength,
                                                                    dashGap: stripeGap)

        return FeatureStyle(
            key: 177,
            color: baseColor,
            lowZoomFadeMask: roadLowZoomFadeMask,
            parseGeometryStyleData: baseGeometryStyle,
            lineRenderPasses: [
                LineRenderPass(key: 177,
                               color: baseColor,
                               lowZoomFadeMask: roadLowZoomFadeMask,
                               parseGeometryStyleData: baseGeometryStyle,
                               includeRoadLabelPath: false,
                               roadPassRole: .fill),
                LineRenderPass(key: 183,
                               color: stripeColor,
                               lowZoomFadeMask: roadLowZoomFadeMask,
                               parseGeometryStyleData: stripeGeometryStyle,
                               includeRoadLabelPath: false,
                               roadPassRole: .detail)
            ],
            roadClassPriority: 15
        )
    }

    private func makeRailwayStyle(colors: [String: SIMD4<Float>]) -> FeatureStyle {
        let borderWidth: Double = 10.0
        let fillWidth: Double = 8.0
        let sleeperWidth: Double = 6.0
        let sleeperLength: Double = 20.0
        let sleeperGap: Double = 14.0
        let borderGeometryStyle = makeRoadGeometryStyle(lineWidth: borderWidth)
        let fillGeometryStyle = makeRoadGeometryStyle(lineWidth: fillWidth)
        let sleeperGeometryStyle = makeSquareDashedRoadGeometryStyle(lineWidth: sleeperWidth,
                                                                     dashLength: sleeperLength,
                                                                     dashGap: sleeperGap)

        return FeatureStyle(
            key: 205,
            color: colors["railway_border"]!,
            lowZoomFadeMask: roadLowZoomFadeMask,
            parseGeometryStyleData: borderGeometryStyle,
            lineRenderPasses: [
                LineRenderPass(key: 205,
                               color: colors["railway_border"]!,
                               lowZoomFadeMask: roadLowZoomFadeMask,
                               parseGeometryStyleData: borderGeometryStyle,
                               includeRoadLabelPath: false,
                               roadPassRole: .casing),
                LineRenderPass(key: 206,
                               color: colors["railway_fill"]!,
                               lowZoomFadeMask: roadLowZoomFadeMask,
                               parseGeometryStyleData: fillGeometryStyle,
                               includeRoadLabelPath: false,
                               roadPassRole: .fill),
                LineRenderPass(key: 207,
                               color: colors["railway_sleepers"]!,
                               lowZoomFadeMask: roadLowZoomFadeMask,
                               parseGeometryStyleData: sleeperGeometryStyle,
                               includeRoadLabelPath: false,
                               roadPassRole: .detail)
            ],
            roadClassPriority: 75
        )
    }

    private func makeSupplementalRoadStyle(roadClass: String,
                                           tileZoom: Int,
                                           colors: [String: SIMD4<Float>]) -> FeatureStyle? {
        if roadClass == "steps" {
            return makeStepsRoadStyle(tileZoom: tileZoom, colors: colors)
        }

        switch roadClass {
        case "minor":
            let fillWidth = makeRoadFillWidth(tileZoom: tileZoom,
                                              baseWidth: 40.0,
                                              minWidthAt10: 5.0,
                                              minWidthAt12: 4.0)
            let fillColor = colors["road_major"]!
            if tileZoom > 13 {
                return makeDualPassRoadStyle(fillKey: 182,
                                             casingKey: 184,
                                             fillColor: fillColor,
                                             fillWidth: fillWidth,
                                             roadClassPriority: 60,
                                             includeRoadLabelPath: false)
            }
            return makeSinglePassRoadStyle(key: 182,
                                           fillColor: fillColor,
                                           fillWidth: fillWidth,
                                           roadClassPriority: 60)
        case "motorway":
            let fillWidth = makeRoadFillWidth(tileZoom: tileZoom,
                                              baseWidth: 60.0,
                                              minWidthAt10: 10.0,
                                              minWidthAt12: 7.0)
            return makeSinglePassRoadStyle(key: 190,
                                           fillColor: colors["road_motorway"]!,
                                           fillWidth: fillWidth,
                                           roadClassPriority: 95)
        case "motorway_link":
            let fillWidth = makeRoadFillWidth(tileZoom: tileZoom,
                                              baseWidth: 30.0,
                                              minWidthAt10: 6.0,
                                              minWidthAt12: 4.0)
            return makeSinglePassRoadStyle(key: 191,
                                           fillColor: colors["road_motorway_link"]!,
                                           fillWidth: fillWidth,
                                           roadClassPriority: 90)
        case "trunk":
            let fillWidth = makeRoadFillWidth(tileZoom: tileZoom,
                                              baseWidth: 54.0,
                                              minWidthAt10: 9.0,
                                              minWidthAt12: 6.0)
            return makeSinglePassRoadStyle(key: 192,
                                           fillColor: colors["road_trunk"]!,
                                           fillWidth: fillWidth,
                                           roadClassPriority: 90)
        case "trunk_link":
            let fillWidth = makeRoadFillWidth(tileZoom: tileZoom,
                                              baseWidth: 28.0,
                                              minWidthAt10: 5.0,
                                              minWidthAt12: 4.0)
            return makeSinglePassRoadStyle(key: 193,
                                           fillColor: colors["road_trunk_link"]!,
                                           fillWidth: fillWidth,
                                           roadClassPriority: 85)
        case "primary_link":
            let fillWidth = makeRoadFillWidth(tileZoom: tileZoom,
                                              baseWidth: 26.0,
                                              minWidthAt10: 5.0,
                                              minWidthAt12: 4.0)
            return makeSinglePassRoadStyle(key: 194,
                                           fillColor: colors["road_primary_link"]!,
                                           fillWidth: fillWidth,
                                           roadClassPriority: 82)
        case "secondary_link":
            let fillWidth = makeRoadFillWidth(tileZoom: tileZoom,
                                              baseWidth: 24.0,
                                              minWidthAt10: 4.0,
                                              minWidthAt12: 3.0)
            return makeSinglePassRoadStyle(key: 195,
                                           fillColor: colors["road_secondary_link"]!,
                                           fillWidth: fillWidth,
                                           roadClassPriority: 78)
        case "tertiary_link":
            let fillWidth = makeRoadFillWidth(tileZoom: tileZoom,
                                              baseWidth: 22.0,
                                              minWidthAt10: 4.0,
                                              minWidthAt12: 3.0)
            return makeSinglePassRoadStyle(key: 196,
                                           fillColor: colors["road_tertiary_link"]!,
                                           fillWidth: fillWidth,
                                           roadClassPriority: 74)
        case "track":
            let fillWidth = makeRoadFillWidth(tileZoom: tileZoom,
                                              baseWidth: 14.0,
                                              minWidthAt10: 2.0,
                                              minWidthAt12: 2.0)
            return FeatureStyle(
                key: 176,
                color: colors["road_track"]!,
                lowZoomFadeMask: roadLowZoomFadeMask,
                parseGeometryStyleData: makeDashedRoadGeometryStyle(lineWidth: fillWidth,
                                                                    dashLength: max(2.0, fillWidth * 1.35),
                                                                    dashGap: max(2.0, fillWidth * 0.95)),
                roadClassPriority: 25
            )
        default:
            break
        }

        let descriptor: (key: UInt8, casingKey: UInt8?, colorName: String, baseWidth: Double, minWidthAt10: Double, minWidthAt12: Double)?
        switch roadClass {
        case "residential":
            descriptor = (170, nil, "road_residential", 24.0, 4.0, 3.0)
        case "unclassified":
            descriptor = (172, nil, "road_unclassified", 20.0, 4.0, 3.0)
        case "path":
            descriptor = nil
        case "cycleway":
            descriptor = (175, nil, "road_cycleway", 14.0, 3.0, 2.0)
        case "track":
            descriptor = nil
        case "footway":
            descriptor = (199, 198, "road_footway", 28.0, 4.0, 3.0)
        case "sidewalk":
            descriptor = (179, nil, "road_sidewalk", 10.0, 2.0, 2.0)
        case "trail":
            descriptor = (180, nil, "road_trail", 12.0, 2.0, 2.0)
        case "crossing":
            descriptor = (181, nil, "road_crossing", 10.0, 2.0, 2.0)
        case "minor":
            descriptor = nil
        default:
            descriptor = nil
        }

        guard let descriptor,
              let color = colors[descriptor.colorName] else {
            return nil
        }

        let fillWidth = makeRoadFillWidth(tileZoom: tileZoom,
                                          baseWidth: descriptor.baseWidth,
                                          minWidthAt10: descriptor.minWidthAt10,
                                          minWidthAt12: descriptor.minWidthAt12)
        if roadClass == "trail" {
            return FeatureStyle(
                key: descriptor.key,
                color: color,
                lowZoomFadeMask: roadLowZoomFadeMask,
                parseGeometryStyleData: makeDashedRoadGeometryStyle(lineWidth: fillWidth,
                                                                    dashLength: fillWidth * 1.6,
                                                                    dashGap: fillWidth * 1.1),
                roadClassPriority: 22
            )
        }
        if tileZoom > 13,
           let casingKey = descriptor.casingKey {
            return makeDualPassRoadStyle(fillKey: descriptor.key,
                                         casingKey: casingKey,
                                         fillColor: color,
                                         fillWidth: fillWidth,
                                         roadClassPriority: roadClassPriority(for: roadClass),
                                         includeRoadLabelPath: false)
        }
        return makeSinglePassRoadStyle(key: descriptor.key,
                                       fillColor: color,
                                       fillWidth: fillWidth,
                                       roadClassPriority: roadClassPriority(for: roadClass))
    }

    private func roadClassPriority(for roadClass: String) -> Int {
        switch roadClass {
        case "motorway":
            return 95
        case "motorway_link", "trunk":
            return 90
        case "trunk_link":
            return 85
        case "primary_link":
            return 82
        case "secondary", "primary", "highway", "major_road", "street", "tertiary":
            return 80
        case "secondary_link":
            return 78
        case "major_rail", "minor_rail", "service_rail":
            return 75
        case "tertiary_link":
            return 74
        case "minor":
            return 60
        case "service", "residential", "driveway", "parking_aisle", "alley", "living_street", "street_limited", "unclassified":
            return 50
        case "pedestrian":
            return 35
        case "track":
            return 25
        case "trail":
            return 22
        case "footway", "sidewalk", "path", "cycleway", "crossing":
            return 20
        case "steps":
            return 15
        default:
            return 10
        }
    }

    private func isLandmarkClass(_ classValue: String?) -> Bool {
        guard let value = normalizedLandmarkClassValue(classValue) else {
            return false
        }
        switch value {
        case "attraction",
             "airport",
             "airfield",
             "heliport",
             "tower",
             "watchtower",
             "bell_tower",
             "church",
             "cathedral",
             "chapel",
             "monastery",
             "abbey",
             "basilica",
             "temple",
             "mosque",
             "synagogue",
             "shrine",
             "square",
             "plaza",
             "piazza",
             "park",
             "national_park",
             "garden",
             "cemetery",
             "landmark",
             "museum",
             "monument",
             "memorial",
             "station",
             "railway_station",
             "university",
             "college",
             "hospital",
             "viewpoint",
             "tourism",
             "zoo",
             "stadium",
             "castle",
             "place_of_worship":
            return true
        default:
            return false
        }
    }

    private func normalizedLandmarkClassValue(_ value: String?) -> String? {
        value?
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private func isNaturalLabelClass(_ classValue: String?) -> Bool {
        guard let value = classValue?.lowercased() else {
            return false
        }
        switch value {
        case "river",
             "stream",
             "canal",
             "bay",
             "reservoir",
             "water_feature",
             "landform":
            return true
        default:
            return false
        }
    }

    private func isOceanLabelClass(_ classValue: String?) -> Bool {
        guard let value = classValue?.lowercased() else {
            return false
        }
        switch value {
        case "ocean":
            return true
        default:
            return false
        }
    }

    private func isSeaLabelClass(_ classValue: String?) -> Bool {
        guard let value = classValue?.lowercased() else {
            return false
        }
        switch value {
        case "sea":
            return true
        default:
            return false
        }
    }

    private func capitalLevel(_ properties: [String: VectorTile_Tile.Value]) -> Int {
        let keyCandidates = ["capital", "captial"]
        for key in keyCandidates {
            if let value = properties[key],
               let parsed = parseIntValue(value) {
                return parsed
            }
        }
        return 0
    }

    private func parseIntValue(_ value: VectorTile_Tile.Value) -> Int? {
        if value.hasIntValue {
            return Int(value.intValue)
        }
        if value.hasSintValue {
            return Int(value.sintValue)
        }
        if value.hasUintValue {
            guard value.uintValue <= UInt64(Int.max) else { return nil }
            return Int(value.uintValue)
        }
        if value.hasFloatValue {
            return Int(value.floatValue)
        }
        if value.hasDoubleValue {
            return Int(value.doubleValue)
        }
        if value.hasBoolValue {
            return value.boolValue ? 1 : 0
        }
        if value.hasStringValue {
            let trimmed = value.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(trimmed)
        }
        return nil
    }

    private func parseBoolValue(_ value: VectorTile_Tile.Value) -> Bool? {
        if value.hasBoolValue {
            return value.boolValue
        }
        if let intValue = parseIntValue(value) {
            return intValue != 0
        }
        if value.hasStringValue {
            let lowercased = value.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            switch lowercased {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                break
            }
        }
        return nil
    }

    private func isTruthy(_ value: VectorTile_Tile.Value?) -> Bool {
        guard let value else {
            return false
        }
        return parseBoolValue(value) ?? false
    }

    private func isUndergroundRailway(properties: [String: VectorTile_Tile.Value]) -> Bool {
        let locationValue = properties["location"]?.stringValue.lowercased() ?? ""
        let structureValue = properties["structure"]?.stringValue.lowercased() ?? ""
        let brunnelValue = properties["brunnel"]?.stringValue.lowercased() ?? ""
        let layerValue = properties["layer"].flatMap(parseIntValue) ?? 0

        return isTruthy(properties["underground"])
            || isTruthy(properties["tunnel"])
            || locationValue.contains("underground")
            || locationValue.contains("subterranean")
            || locationValue.contains("tunnel")
            || structureValue == "tunnel"
            || brunnelValue == "tunnel"
            || layerValue < 0
    }

    private func continentLabelSize(for tileZoom: Int) -> Float {
        switch tileZoom {
        case ...9:
            return 52.0
        case 10:
            return 56.0
        default:
            return 60.0
        }
    }

    private func oceanLabelSize(for tileZoom: Int) -> Float {
        switch tileZoom {
        case ...1:
            return 27.0
        case 2:
            return 24.0
        default:
            return 18.0
        }
    }

    private func seaLabelSize(for tileZoom: Int) -> Float {
        switch tileZoom {
        case ...1:
            return 40.0
        case 2:
            return 34.0
        default:
            return 26.0
        }
    }

    private func waterLabelStrokeWidth(for sizePx: Float) -> Float {
        sizePx * 0.14
    }

    private func capitalSize(level: Int, tileZoom: Int) -> Float {
        let normalized = max(1, level)
        let baseSize: Float
        let minimumSize: Float
        switch tileZoom {
        case ...9:
            baseSize = 52.0
            minimumSize = 40.0
        case 10:
            baseSize = 56.0
            minimumSize = 42.0
        case 11:
            baseSize = 52.0
            minimumSize = 40.0
        case 12:
            baseSize = 48.0
            minimumSize = 38.0
        case 13:
            baseSize = 44.0
            minimumSize = 36.0
        default:
            baseSize = 42.0
            minimumSize = 34.0
        }
        if normalized <= 2 {
            return baseSize
        }
        return max(minimumSize, baseSize - Float(normalized - 2) * 4.0)
    }

    private func cityLabelSize(for tileZoom: Int) -> Float {
        switch tileZoom {
        case ...9:
            return 30.0
        case 10:
            return 34.0
        case 11:
            return 38.0
        case 12:
            return 38.0
        case 13:
            return 36.0
        default:
            return 34.0
        }
    }

    private func smallSettlementLabelSize(for tileZoom: Int) -> Float {
        switch tileZoom {
        case ...9:
            return 22.0
        case 10:
            return 26.0
        case 11:
            return 30.0
        case 12:
            return 34.0
        default:
            return 38.0
        }
    }

    private func districtLabelSize(for tileZoom: Int) -> Float {
        switch tileZoom {
        case ...9:
            return 18.0
        case 10:
            return 22.0
        case 11:
            return 24.0
        case 12:
            return 26.0
        case 13:
            return 28.0
        default:
            return 30.0
        }
    }

    private func landmarkLabelSize(for tileZoom: Int) -> Float {
        switch tileZoom {
        case ...9:
            return 18.0
        case 10:
            return 22.0
        case 11...12:
            return 26.0
        case 13:
            return 28.0
        default:
            return 30.0
        }
    }

    private func poiLabelSize(for tileZoom: Int) -> Float {
        switch tileZoom {
        case ...12:
            return 20.0
        case 13:
            return 24.0
        case 14:
            return 26.0
        default:
            return 28.0
        }
    }

    private func houseNumberLabelSize(for tileZoom: Int) -> Float {
        switch tileZoom {
        case ...16:
            return 24.0
        case 17:
            return 26.0
        default:
            return 28.0
        }
    }
    
    func makeStyle(data: DetFeatureStyleData) -> FeatureStyle {
        let tile = data.tile
        let properties = data.properties
        let classValue = properties["class"]?.stringValue ?? properties["type"]?.stringValue
        let typeValue = properties["type"]?.stringValue
        let labelClassValue = properties["class"]?.stringValue

        // Color palette (RGBA, normalized to 0.0-1.0)
        let layers = layerStyles
        let roads = layers.roads
        let railway = layers.railway
        let standardLayers = MapboxDefaultMapStyleConfiguration.LayerStyles.standard
        let waterColor = layers.water == standardLayers.water ? mapBaseColors.getWaterColor() : layers.water
        let grassColor = layers.grass == standardLayers.grass ? mapBaseColors.getLandCoverColor() : layers.grass
        let colors = [
            "admin_boundary": layers.adminBoundary,
            "admin_level_1": layers.adminLevel1,
            "water": waterColor,
            "river": layers.river,
            "landcover_forest": layers.forest,
            "landcover_scrub": layers.scrub,
            "landcover_grass": grassColor,
            "landcover_crop": layers.crop,
            "landcover_snow": layers.snow,
            "hillshade_shadow": layers.hillshadeShadow,
            "hillshade_highlight": layers.hillshadeHighlight,
            "contour": layers.contour,
            "road_major": roads.major,
            "road_minor": roads.minor,
            "road_pedestrian": roads.pedestrian,
            "road_motorway": roads.motorway,
            "road_motorway_link": roads.motorwayLink,
            "road_trunk": roads.trunk,
            "road_trunk_link": roads.trunkLink,
            "road_primary_link": roads.primaryLink,
            "road_secondary_link": roads.secondaryLink,
            "road_tertiary_link": roads.tertiaryLink,
            "road_residential": roads.residential,
            "road_living_street": roads.livingStreet,
            "road_unclassified": roads.unclassified,
            "road_street_limited": roads.streetLimited,
            "road_path": roads.path,
            "road_cycleway": roads.cycleway,
            "road_track": roads.track,
            "road_steps_base": roads.stepsBase,
            "road_steps": roads.steps,
            "road_footway": roads.footway,
            "road_sidewalk": roads.sidewalk,
            "road_trail": roads.trail,
            "road_crossing": roads.crossing,
            "road_minor_local": roads.minorLocal,
            "road_misc": roads.misc,
            "fallback": SIMD4<Float>(0.5, 0.5, 0.5, 0.5),          // Neutral gray
            "background": mapBaseColors.getTileBgColor(),
            "border": SIMD4<Float>(1.0, 0.0, 0.0, 1.0),
            
            "building": featureStyles.buildingFillColor,               // Yandex-like light beige gray
            "park": layers.park,
            "residential": layers.residential,
            "industrial": layers.industrial,
            "farmland": layers.farmland,
            "railway_border": railway.border,
            "railway_fill": railway.fill,
            "railway_sleepers": railway.sleepers,
            "aeroway": layers.aeroway
        ]
        
        let name_en = properties["name_en"]?.stringValue
        if data.layerName.hasSuffix("label") || name_en == "Moscow" {
            if let labelTextStyle = makeLabelTextStyle(layerName: data.layerName,
                                                       classValue: labelClassValue,
                                                       tileZoom: tile.z,
                                                       properties: properties) {
                return FeatureStyle(
                    key: labelKey,
                    color: colors["fallback"]!,
                    parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0),
                    labelTextStyle: labelTextStyle
                )
            }
        }
        
        switch data.layerName {
        case "background":
            return FeatureStyle(
                key: 1,
                color: colors["background"]!,
                parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0)
            )
        case "landcover":
            if tile.z > 13 {
                return FeatureStyle(
                    key: fallbackKey,
                    color: colors["fallback"]!,
                    parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0)
                )
            }
            switch classValue?.lowercased() {
            case "forest", "wood":
                if tile.z <= 5 {
                    return FeatureStyle(
                        key: fallbackKey,
                        color: colors["fallback"]!,
                        parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0)
                    )
                }
                return FeatureStyle(
                    key: 11, // Bottom layer, above fallback
                    color: colors["landcover_forest"]!,
                    parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0)
                )
            case "scrub":
                return FeatureStyle(
                    key: 12,
                    color: colors["landcover_scrub"]!,
                    parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0)
                )
            case "grass":
                return FeatureStyle(
                    key: 12, // Above forest
                    color: colors["landcover_grass"]!,
                    parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0)
                )
            case "crop", "farmland":
                return FeatureStyle(
                    key: 12,
                    color: colors["landcover_crop"]!,
                    parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0)
                )
            case "snow", "ice":
                return FeatureStyle(
                    key: 13,
                    color: colors["landcover_snow"]!,
                    parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0)
                )
            default:
                return FeatureStyle(
                    key: 10,
                    color: colors["landcover_grass"]!,
                    parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0)
                )
            }

        case "hillshade":
            if tile.z < 5 || tile.z > 13 {
                return fallbackStyle
            }
            let hillshadeClass = classValue?.lowercased()
            return FeatureStyle(
                key: 14,
                color: hillshadeClass == "highlight" ? colors["hillshade_highlight"]! : colors["hillshade_shadow"]!,
                parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0)
            )

        case "contour":
            return fallbackStyle

        case "water":
            if classValue == "river" {
                return FeatureStyle(
                    key: 21, // Above general water
                    color: colors["river"]!,
                    parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 3) // Thin line for rivers
                )
            }
            return FeatureStyle(
                key: 20, // Above landcover
                color: colors["water"]!,
                parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0) // Filled polygon
            )
            
        case "waterway":
            if tile.z < 8 {
                return FeatureStyle(
                    key: fallbackKey,
                    color: colors["fallback"]!,
                    parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0)
                )
            }
            let lineWidth: Double
            if classValue == "river" || classValue == "canal" {
                lineWidth = 3
            } else {
                lineWidth = 2
            }
            return FeatureStyle(
                key: 22, // Above water polygons
                color: colors["river"]!,
                parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: lineWidth)
            )

        case "admin":
            if let adminLevel = properties["admin_level"]?.uintValue {
                if adminLevel == 1 {
                    return FeatureStyle(
                        key: 102, // Above water
                        color: colors["admin_level_1"]!,
                        lowZoomFadeMask: 1.0,
                        parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 6)
                    )
                } else if adminLevel == 2 {
                    return FeatureStyle(
                        key: 101,
                        color: colors["admin_boundary"]!,
                        lowZoomFadeMask: 1.0,
                        parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 6)
                    )
                }
            }
            return FeatureStyle(
                key: 100,
                color: colors["admin_boundary"]!,
                lowZoomFadeMask: 1.0,
                parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 7.5)
            )

        case "road":
            let roadClassProperty = properties["class"]?.stringValue.lowercased()
            let roadTypeValue = properties["type"]?.stringValue.lowercased()
            if roadClassProperty == "path", roadTypeValue == "path" {
                return fallbackStyle
            }
            let normalizedRoadClass = roadClassProperty == "path"
                ? (roadTypeValue ?? roadClassProperty)
                : classValue?.lowercased()

            if normalizedRoadClass == "major_rail" ||
               normalizedRoadClass == "minor_rail" ||
               normalizedRoadClass == "service_rail" {
                guard tile.z >= 13 else {
                    return fallbackStyle
                }
                guard isUndergroundRailway(properties: properties) == false else {
                    return fallbackStyle
                }
                return bridgeifyRoadStyleIfNeeded(makeRailwayStyle(colors: colors),
                                                  properties: properties,
                                                  tileZoom: tile.z)
            }

            if normalizedRoadClass == "footway" {
                let tileZoom = tile.z
                let footwayColor = colors["road_footway"]!
                let fillWidth = makeRoadFillWidth(tileZoom: tileZoom,
                                                  baseWidth: 10.0,
                                                  minWidthAt10: 2.0,
                                                  minWidthAt12: 2.0)
                return bridgeifyRoadStyleIfNeeded(
                    decorateRoadStyleIfNeeded(
                        makeSinglePassRoadStyle(key: 178,
                                                fillColor: footwayColor,
                                                fillWidth: fillWidth,
                                                roadClassPriority: 20),
                        properties: properties,
                        normalizedRoadClass: normalizedRoadClass,
                        tileZoom: tile.z
                    ),
                    properties: properties,
                    tileZoom: tile.z
                )
            }

            if normalizedRoadClass == "crossing" {
                guard tile.z >= zebraCrossingMinimumZoom else {
                    return fallbackStyle
                }
                return makeZebraCrossingStyle(tileZoom: tile.z)
            }

            if normalizedRoadClass == "pedestrian" {
                let tileZoom = tile.z
                let roadColor = colors["road_pedestrian"]!
                let fillWidth = makeRoadFillWidth(tileZoom: tileZoom,
                                                  baseWidth: 28.0,
                                                  minWidthAt10: 4.0,
                                                  minWidthAt12: 3.0)
                let style: FeatureStyle
                if tileZoom > 13 {
                    style = makeDualPassRoadStyle(fillKey: 199,
                                                  casingKey: 198,
                                                  fillColor: roadColor,
                                                  fillWidth: fillWidth,
                                                  roadClassPriority: 35,
                                                  includeRoadLabelPath: false)
                } else {
                    style = FeatureStyle(
                        key: 199,
                        color: roadColor,
                        lowZoomFadeMask: roadLowZoomFadeMask,
                        parseGeometryStyleData: makeRoadGeometryStyle(lineWidth: fillWidth),
                        roadClassPriority: 35
                    )
                }
                return bridgeifyRoadStyleIfNeeded(style,
                                                  properties: properties,
                                                  tileZoom: tile.z)
            }

            if normalizedRoadClass == "sidewalk" || normalizedRoadClass == "path" {
                let tileZoom = tile.z
                let sidewalkColor = colors["road_sidewalk"]!
                let fillWidth = makeRoadFillWidth(tileZoom: tileZoom,
                                                  baseWidth: 8.0,
                                                  minWidthAt10: 2.0,
                                                  minWidthAt12: 2.0)
                return bridgeifyRoadStyleIfNeeded(
                    decorateRoadStyleIfNeeded(
                        makeSinglePassRoadStyle(key: 179,
                                                fillColor: sidewalkColor,
                                                fillWidth: fillWidth,
                                                roadClassPriority: 20),
                        properties: properties,
                        normalizedRoadClass: normalizedRoadClass,
                        tileZoom: tile.z
                    ),
                    properties: properties,
                    tileZoom: tile.z
                )
            }

            if normalizedRoadClass == "secondary" || normalizedRoadClass == "primary" || normalizedRoadClass == "highway" ||
               normalizedRoadClass == "major_road" || normalizedRoadClass == "street" || normalizedRoadClass == "tertiary" {
                let tileZoom = tile.z
                let roadColor: SIMD4<Float>
                if tileZoom <= 7 {
                    roadColor = SIMD4<Float>(0.75, 0.75, 0.75, 0.5)
                } else if tileZoom <= 9 {
                    roadColor = SIMD4<Float>(0.85, 0.85, 0.85, 0.8)
                } else {
                    roadColor = colors["road_major"]!
                }
                let fillWidth = makeRoadFillWidth(tileZoom: tileZoom,
                                                  baseWidth: 80.0,
                                                  minWidthAt10: 12.0,
                                                  minWidthAt12: 8.0)
                let roadLabelTextStyle = makeRoadLabelTextStyle()
                let style: FeatureStyle
                if tileZoom > 13 {
                    style = makeDualPassRoadStyle(fillKey: 203,
                                                  casingKey: 201,
                                                  fillColor: roadColor,
                                                  fillWidth: fillWidth,
                                                  roadClassPriority: 80,
                                                  roadLabelTextStyle: roadLabelTextStyle)
                } else {
                    style = FeatureStyle(
                        key: 201,
                        color: roadColor,
                        lowZoomFadeMask: roadLowZoomFadeMask,
                        parseGeometryStyleData: makeRoadGeometryStyle(lineWidth: fillWidth),
                        includeRoadLabelPath: true,
                        roadClassPriority: 80,
                        roadLabelTextStyle: roadLabelTextStyle
                    )
                }
                return bridgeifyRoadStyleIfNeeded(
                    decorateRoadStyleIfNeeded(style,
                                              properties: properties,
                                              normalizedRoadClass: normalizedRoadClass,
                                              tileZoom: tile.z),
                    properties: properties,
                    tileZoom: tile.z
                )
            }
            
            if normalizedRoadClass == "service" || normalizedRoadClass == "residential" ||
               normalizedRoadClass == "driveway" ||
               normalizedRoadClass == "parking_aisle" || normalizedRoadClass == "alley" ||
               normalizedRoadClass == "living_street" || normalizedRoadClass == "street_limited" {
                let tileZoom = tile.z
                let roadColor: SIMD4<Float>
                if tileZoom <= 7 {
                    roadColor = SIMD4<Float>(0.7, 0.7, 0.7, 0.45)
                } else if tileZoom <= 9 {
                    roadColor = SIMD4<Float>(0.8, 0.8, 0.8, 0.75)
                } else {
                    roadColor = colors["road_major"]!
                }
                let fillWidth = makeRoadFillWidth(tileZoom: tileZoom,
                                                  baseWidth: 50.0,
                                                  minWidthAt10: 8.0,
                                                  minWidthAt12: 6.0)
                let roadLabelTextStyle = makeRoadLabelTextStyle()
                let style: FeatureStyle
                if tileZoom > 13 {
                    style = makeDualPassRoadStyle(fillKey: 202,
                                                  casingKey: 200,
                                                  fillColor: roadColor,
                                                  fillWidth: fillWidth,
                                                  roadClassPriority: 50,
                                                  roadLabelTextStyle: roadLabelTextStyle)
                } else {
                    style = FeatureStyle(
                        key: 200,
                        color: roadColor,
                        lowZoomFadeMask: roadLowZoomFadeMask,
                        parseGeometryStyleData: makeRoadGeometryStyle(lineWidth: fillWidth),
                        includeRoadLabelPath: true,
                        roadClassPriority: 50,
                        roadLabelTextStyle: roadLabelTextStyle
                    )
                }
                return bridgeifyRoadStyleIfNeeded(
                    decorateRoadStyleIfNeeded(style,
                                              properties: properties,
                                              normalizedRoadClass: normalizedRoadClass,
                                              tileZoom: tile.z),
                    properties: properties,
                    tileZoom: tile.z
                )
            }

            if let normalizedRoadClass,
               let supplementalStyle = makeSupplementalRoadStyle(roadClass: normalizedRoadClass,
                                                                 tileZoom: tile.z,
                                                                 colors: colors) {
                return bridgeifyRoadStyleIfNeeded(
                    decorateRoadStyleIfNeeded(supplementalStyle,
                                              properties: properties,
                                              normalizedRoadClass: normalizedRoadClass,
                                              tileZoom: tile.z),
                    properties: properties,
                    tileZoom: tile.z
                )
            }

            return fallbackStyle

        case "building":
            return FeatureStyle(
                key: 210, // Topmost layer
                color: featureStyles.buildingFillColor,
                parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0), // Filled polygon
                usesExtrusion: true,
                extrusionHeightScale: 8.0,
                extrusionAnchorZoom: 16
            )

        case "structure":
            if classValue?.lowercased() == "land", typeValue?.lowercased() == "bridge" {
                return FeatureStyle(
                    key: 36,
                    color: colors["background"]!,
                    parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0),
                    linePlacement: .bridgeOverlay
                )
            }
            return fallbackStyle
            
        case "landuse", "landuse_overlay":
            if tile.z < 9 {
                return FeatureStyle(
                    key: fallbackKey,
                    color: colors["fallback"]!,
                    parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0)
                )
            }
            switch classValue {
            case "park", "cemetery", "pitch":
                if tile.z < 13 {
                    return FeatureStyle(
                        key: fallbackKey,
                        color: colors["fallback"]!,
                        parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0)
                    )
                }
                return FeatureStyle(
                    key: 30,
                    color: colors["park"]!,
                    lowZoomFadeMask: tile.z == 13 ? landuseLowZoomFadeMask : 0.0,
                    parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0)
                )
            case "residential", "suburb", "neighbourhood":
                if tile.z < 13 {
                    return FeatureStyle(
                        key: fallbackKey,
                        color: colors["fallback"]!,
                        parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0)
                    )
                }
                return FeatureStyle(
                    key: 31,
                    color: colors["residential"]!,
                    lowZoomFadeMask: tile.z == 13 ? landuseLowZoomFadeMask : 0.0,
                    parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0)
                )
            case "industrial", "commercial":
                if tile.z < 13 {
                    return FeatureStyle(
                        key: fallbackKey,
                        color: colors["fallback"]!,
                        parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0)
                    )
                }
                return FeatureStyle(
                    key: 32,
                    color: colors["industrial"]!,
                    lowZoomFadeMask: tile.z == 13 ? landuseLowZoomFadeMask : 0.0,
                    parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0)
                )
            case "farmland", "farm", "orchard":
                if tile.z < 13 {
                    return FeatureStyle(
                        key: fallbackKey,
                        color: colors["fallback"]!,
                        parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0)
                    )
                }
                return FeatureStyle(
                    key: 33,
                    color: colors["farmland"]!,
                    lowZoomFadeMask: tile.z == 13 ? landuseLowZoomFadeMask : 0.0,
                    parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0)
                )
            case "grass":
                if tile.z < 13 {
                    return FeatureStyle(
                        key: fallbackKey,
                        color: colors["fallback"]!,
                        parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0)
                    )
                }
                return FeatureStyle(
                    key: 34,
                    color: colors["landcover_grass"]!,
                    lowZoomFadeMask: tile.z == 13 ? landuseLowZoomFadeMask : 0.0,
                    parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0)
                )
            case "wood", "scrub":
                return FeatureStyle(
                    key: 35,
                    color: colors["landcover_forest"]!,
                    parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0)
                )
            default:
                if tile.z < 13 {
                    return FeatureStyle(
                        key: fallbackKey,
                        color: colors["fallback"]!,
                        parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0)
                    )
                }
                return FeatureStyle(
                    key: 30,
                    color: colors["landcover_grass"]!,
                    lowZoomFadeMask: tile.z == 13 ? landuseLowZoomFadeMask : 0.0,
                    parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0)
                )
            }
            
        case "aeroway":
            if tile.z < 11 {
                return FeatureStyle(
                    key: fallbackKey,
                    color: colors["fallback"]!,
                    parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0)
                )
            }
            if classValue == "runway" || classValue == "taxiway" {
                return FeatureStyle(
                    key: 208,
                    color: colors["aeroway"]!,
                    parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 12)
                )
            }
            return FeatureStyle(
                key: 208,
                color: colors["aeroway"]!,
                parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0)
            )
        case "border":
            return FeatureStyle(
                key: 211,
                color: colors["border"]!,
                parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 0)
            )

        default:
            return FeatureStyle(
                key: fallbackKey, // Bottom-most
                color: colors["fallback"]!,
                parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 1)
            )
        }
    }
}
