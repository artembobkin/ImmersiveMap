// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation
import MetalKit
internal import SwiftEarcut


class TileMvtParser {
    private static let dashEpsilon: Float = 0.0001
    private static let minClippedRoadLabelFragmentLength: Float = 256.0
    static let complexOceanHoleSplitThreshold = 64
    let determineFeatureStyle               : DetermineFeatureStyle
    private let decodePolygon               : DecodePolygon = DecodePolygon()
    private let decodeLine                  : DecodeLine = DecodeLine()
    private let decodePoint                 : DecodePoint = DecodePoint()
    private let config                      : ImmersiveMapSettings
    private let labelTextResolver           : VectorTileLabelTextResolver
    private let labelLanguagePreferences    : VectorTileLabelLanguagePreferences
    private let glyphCoverage               : VectorTileLabelGlyphCoverage
    private let labelDecisionEngine         : VectorTileLabelDecisionEngine
    private let labelProviderProfile        : any VectorTileLabelProviderProfile
    private let poiSpriteResolver           : PoiSpriteResolver = PoiSpriteResolver()
    private let crosswalkZebraBuilder       : CrosswalkZebraGeometryBuilder = CrosswalkZebraGeometryBuilder()
    private let roadDirectionArrowBuilder   : RoadDirectionArrowGeometryBuilder = RoadDirectionArrowGeometryBuilder()
    let tileExtent = Double(4096)

    /// The MVT layer that carries roads: `road` in the Mapbox schema, `transportation`
    /// in OpenMapTiles. Only this layer flows through the seamless, casing-under-fill
    /// separate-road rendering path.
    private static func isSeparateRoadLayer(_ layerName: String) -> Bool {
        layerName == "road" || layerName == "transportation"
    }

    
    init(determineFeatureStyle: DetermineFeatureStyle,
         labelProviderProfile: any VectorTileLabelProviderProfile,
         config: ImmersiveMapSettings,
         glyphCoverage: VectorTileLabelGlyphCoverage) {
        self.determineFeatureStyle = determineFeatureStyle
        self.config = config
        self.glyphCoverage = glyphCoverage
        self.labelTextResolver = VectorTileLabelTextResolver(glyphCoverage: glyphCoverage)
        self.labelLanguagePreferences = VectorTileLabelLanguagePreferences.from(
            settingsLanguage: config.labels.language,
            fallbackPolicy: config.labels.fallbackPolicy
        )
        self.labelProviderProfile = labelProviderProfile
        self.labelDecisionEngine = VectorTileLabelDecisionEngine(
            profile: labelProviderProfile,
            textResolver: labelTextResolver
        )
    }
    
    func parse(
        tile: Tile,
        mvtData: Data
    ) throws -> ParsedTile {
        let vectorTile = try VectorTile_Tile(serializedBytes: mvtData)
        let readingStageResult = readingStage(vectorTile: vectorTile, tile: tile)
        let unificationResult = unificationStage(readingStageResult: readingStageResult)

        return ParsedTile(
            drawingPolygon: unificationResult.drawingPolygon,
            drawingRoadPhases: unificationResult.drawingRoadPhases,
            drawingBridgePolygon: unificationResult.drawingBridgePolygon,
            drawingExtruded: unificationResult.drawingExtruded,
            styles: unificationResult.styles,
            overviewStyleMasks: unificationResult.overviewStyleMasks,
            bridgeStyles: unificationResult.bridgeStyles,
            bridgeOverviewStyleMasks: unificationResult.bridgeOverviewStyleMasks,
            tile: tile,
            textLabels: readingStageResult.textLabels,
            roadTextLabels: readingStageResult.roadTextLabels,
            parseLayerTimings: readingStageResult.layerTimings
        )
    }

    private func linePath(points: [SIMD2<Float>]) -> [SIMD2<Int16>] {
        points.map { point in
            let clampedX = min(max(point.x, 0.0), Float(tileExtent))
            let clampedY = min(max(point.y, 0.0), Float(tileExtent))
            return SIMD2(Int16(clamping: Int(clampedX.rounded())),
                         Int16(clamping: Int(clampedY.rounded())))
        }
    }

    private func isPointInsideTile(_ point: Point) -> Bool {
        point.x >= 0 &&
        point.x <= Int32(tileExtent) &&
        point.y >= 0 &&
        point.y <= Int32(tileExtent)
    }

    private func isPointStrictlyInsideTile(_ point: SIMD2<Float>) -> Bool {
        point.x > 0.0 &&
        point.x < Float(tileExtent) &&
        point.y > 0.0 &&
        point.y < Float(tileExtent)
    }

    private func isRoadBoundaryContinuationEndpoint(_ point: SIMD2<Float>?) -> Bool {
        guard let point else {
            return false
        }
        return LineClipper.isOnTileBoundary(point, tileExtent: Float(tileExtent))
    }

    private func shouldExtendRoadBoundaryEndpoint(_ point: SIMD2<Float>?) -> Bool {
        guard let point else {
            return false
        }

        let extent = Float(tileExtent)
        let epsilon: Float = 0.0001
        return abs(point.x - extent) <= epsilon || abs(point.y - extent) <= epsilon
    }

    private func shouldExtendClippedRoadEndpoint(_ point: SIMD2<Float>?) -> Bool {
        guard let point else {
            return false
        }

        let extent = Float(tileExtent)
        return point.x > extent || point.y > extent
    }

    private func roadStructureKind(attributes: [String: VectorTile_Tile.Value]) -> RoadStructureKind {
        let locationValue = attributes["location"]?.stringValue.lowercased() ?? ""
        let structureValue = attributes["structure"]?.stringValue.lowercased() ?? ""
        let brunnelValue = attributes["brunnel"]?.stringValue.lowercased() ?? ""
        let layerValue = attributes["layer"].flatMap(parseIntValue) ?? 0

        let isTunnel = isTruthy(attributes["underground"])
            || isTruthy(attributes["tunnel"])
            || locationValue.contains("underground")
            || locationValue.contains("subterranean")
            || locationValue.contains("tunnel")
            || locationValue.contains("underwater")
            || structureValue == "tunnel"
            || brunnelValue == "tunnel"
            || layerValue < 0
        if isTunnel {
            return .tunnel
        }

        let isBridge = isTruthy(attributes["bridge"])
            || structureValue == "bridge"
            || brunnelValue == "bridge"
            || locationValue.contains("bridge")
            || locationValue.contains("elevated")
            || layerValue > 0
        if isBridge {
            return .bridge
        }

        return .ground
    }

    private func roadLayerValue(attributes: [String: VectorTile_Tile.Value]) -> Int {
        attributes["layer"].flatMap(parseIntValue) ?? 0
    }

    private func buildHighZoomRoadSharedPointCounts(layer: VectorTile_Tile.Layer,
                                                    tile: Tile) -> [RoadConnectionPointKey: Int] {
        let lineClipper = LineClipper()
        var pointCounts: [RoadConnectionPointKey: Int] = [:]

        for feature in layer.features where feature.type == .linestring {
            let attributes = decodeAttributes(feature: feature, layer: layer)
            let style = determineFeatureStyle.makeStyle(data: DetFeatureStyleData(layerName: layer.name,
                                                                                  properties: attributes,
                                                                                  tile: tile))
            guard style.key != 0 else {
                continue
            }

            let lines = normalize(decodeLine.decode(geometry: feature.geometry), layer: layer)
            for line in lines {
                let fragments = lineClipper.clip(line: line, tileExtent: Float(tileExtent))
                for fragment in fragments {
                    for point in fragment.points {
                        pointCounts[RoadConnectionPointKey(point: point), default: 0] += 1
                    }
                }
            }
        }

        return pointCounts
    }

    private func lineLength(points: [SIMD2<Float>]) -> Float {
        guard points.count >= 2 else {
            return 0.0
        }

        var totalLength: Float = 0.0
        for index in 1..<points.count {
            totalLength += simd_length(points[index] - points[index - 1])
        }
        return totalLength
    }

    private func shouldIncludeRoadLabelFragment(_ fragment: ClippedLineFragment) -> Bool {
        guard fragment.points.count >= 2 else {
            return false
        }

        let isEdgeClipped = fragment.startClipped || fragment.endClipped
        guard isEdgeClipped else {
            return true
        }

        return lineLength(points: fragment.points) >= Self.minClippedRoadLabelFragmentLength
    }

    private func shouldRenderCrosswalkZebra(style: FeatureStyle,
                                            usesSeparateRoadRendering: Bool,
                                            roadStructure: RoadStructureKind) -> Bool {
        usesSeparateRoadRendering
        && style.roadDecorationKind == .zebraCrossing
        && roadStructure != .tunnel
    }

    private func renderFragments(for fragment: ClippedLineFragment,
                                 styleData: ParseGeometryStyleData) -> [ClippedLineFragment] {
        guard styleData.usesDashPattern else {
            return [fragment]
        }
        guard styleData.dashResetsPerSegment == false else {
            guard fragment.points.count >= 2 else {
                return [fragment]
            }

            var segmentedFragments: [ClippedLineFragment] = []
            segmentedFragments.reserveCapacity(fragment.points.count - 1)

            func direction(from start: SIMD2<Float>, to end: SIMD2<Float>) -> SIMD2<Float>? {
                let delta = end - start
                let length = simd_length(delta)
                guard length > Self.dashEpsilon else {
                    return nil
                }
                return delta / length
            }

            func isTurn(previous: SIMD2<Float>, current: SIMD2<Float>) -> Bool {
                let cross = previous.x * current.y - previous.y * current.x
                let dot = previous.x * current.x + previous.y * current.y
                return abs(cross) > 0.001 || dot < 0.999
            }

            let cornerInset = max(Float(styleData.lineWidth), Float(styleData.dashLength))
            for index in 0..<(fragment.points.count - 1) {
                let segmentStart = fragment.points[index]
                let segmentEnd = fragment.points[index + 1]
                guard let segmentDirection = direction(from: segmentStart, to: segmentEnd) else {
                    continue
                }

                var trimmedStart = segmentStart
                var trimmedEnd = segmentEnd

                if index > 0,
                   let previousDirection = direction(from: fragment.points[index - 1], to: segmentStart),
                   isTurn(previous: previousDirection, current: segmentDirection) {
                    trimmedStart += segmentDirection * cornerInset
                }

                if index < fragment.points.count - 2,
                   let nextDirection = direction(from: segmentEnd, to: fragment.points[index + 2]),
                   isTurn(previous: segmentDirection, current: nextDirection) {
                    trimmedEnd -= segmentDirection * cornerInset
                }

                if simd_length(trimmedEnd - trimmedStart) <= Self.dashEpsilon {
                    continue
                }

                segmentedFragments.append(contentsOf: centeredFullDashFragmentsForSegment(start: trimmedStart,
                                                                                          end: trimmedEnd,
                                                                                          dashLength: Float(styleData.dashLength),
                                                                                          dashGap: Float(styleData.dashGap)))
            }
            return segmentedFragments
        }
        return dashedFragments(from: fragment,
                               dashLength: Float(styleData.dashLength),
                               dashGap: Float(styleData.dashGap))
    }

    private func centeredFullDashFragmentsForSegment(start: SIMD2<Float>,
                                                     end: SIMD2<Float>,
                                                     dashLength: Float,
                                                     dashGap: Float) -> [ClippedLineFragment] {
        let delta = end - start
        let segmentLength = simd_length(delta)
        guard segmentLength > Self.dashEpsilon,
              dashLength > Self.dashEpsilon,
              dashGap > Self.dashEpsilon else {
            return []
        }

        let direction = delta / segmentLength
        let patternLength = dashLength + dashGap
        let dashCount = Int(((segmentLength + dashGap) / patternLength).rounded(.down))
        guard dashCount > 0 else {
            return []
        }

        let occupiedLength = Float(dashCount) * dashLength + Float(max(0, dashCount - 1)) * dashGap
        let leadingInset = max(0, (segmentLength - occupiedLength) * 0.5)
        let firstDashStart = start + direction * leadingInset

        var dashed: [ClippedLineFragment] = []
        dashed.reserveCapacity(dashCount)
        for index in 0..<dashCount {
            let offset = Float(index) * patternLength
            let dashStart = firstDashStart + direction * offset
            let dashEnd = dashStart + direction * dashLength
            dashed.append(ClippedLineFragment(points: [dashStart, dashEnd],
                                             startClipped: false,
                                             endClipped: false))
        }
        return dashed
    }

    private func dashedFragments(from fragment: ClippedLineFragment,
                                 dashLength: Float,
                                 dashGap: Float) -> [ClippedLineFragment] {
        guard fragment.points.count >= 2,
              dashLength > Self.dashEpsilon,
              dashGap > Self.dashEpsilon else {
            return [fragment]
        }

        var dashed: [ClippedLineFragment] = []
        var currentDashPoints: [SIMD2<Float>] = []
        currentDashPoints.reserveCapacity(fragment.points.count)

        var isDash = true
        var remainingPatternLength = dashLength
        var dashStartedAtFragmentStart = true

        func pointsEqual(_ lhs: SIMD2<Float>, _ rhs: SIMD2<Float>) -> Bool {
            abs(lhs.x - rhs.x) <= Self.dashEpsilon && abs(lhs.y - rhs.y) <= Self.dashEpsilon
        }

        func appendPointIfNeeded(_ point: SIMD2<Float>) {
            if let last = currentDashPoints.last, pointsEqual(last, point) {
                return
            }
            currentDashPoints.append(point)
        }

        func finalizeDash(endedAtFragmentEnd: Bool) {
            guard currentDashPoints.count >= 2 else {
                currentDashPoints.removeAll(keepingCapacity: true)
                return
            }
            dashed.append(ClippedLineFragment(points: currentDashPoints,
                                             startClipped: dashStartedAtFragmentStart ? fragment.startClipped : false,
                                             endClipped: endedAtFragmentEnd ? fragment.endClipped : false))
            currentDashPoints.removeAll(keepingCapacity: true)
        }

        for index in 0..<(fragment.points.count - 1) {
            let segmentStart = fragment.points[index]
            let segmentEnd = fragment.points[index + 1]
            let segmentDelta = segmentEnd - segmentStart
            let segmentLength = simd_length(segmentDelta)
            guard segmentLength > Self.dashEpsilon else {
                continue
            }

            let direction = segmentDelta / segmentLength
            var currentPoint = segmentStart
            var remainingSegmentLength = segmentLength

            while remainingSegmentLength > Self.dashEpsilon {
                let traveledLength = min(remainingPatternLength, remainingSegmentLength)
                let nextPoint = currentPoint + direction * traveledLength
                let reachesFragmentEnd = index == fragment.points.count - 2
                    && remainingSegmentLength - traveledLength <= Self.dashEpsilon

                if isDash {
                    if currentDashPoints.isEmpty {
                        appendPointIfNeeded(currentPoint)
                    }
                    appendPointIfNeeded(nextPoint)
                }

                currentPoint = nextPoint
                remainingSegmentLength -= traveledLength
                remainingPatternLength -= traveledLength

                if remainingPatternLength <= Self.dashEpsilon {
                    if isDash {
                        finalizeDash(endedAtFragmentEnd: reachesFragmentEnd)
                    }
                    isDash.toggle()
                    remainingPatternLength = isDash ? dashLength : dashGap
                    dashStartedAtFragmentStart = false
                }
            }
        }

        if isDash, currentDashPoints.isEmpty == false {
            finalizeDash(endedAtFragmentEnd: true)
        }

        return dashed
    }

    private struct LocalizedFallbackLabel {
        let names: [String: String]
        let latitude: Double
        let longitude: Double
        let sortKey: Int
        let styleClass: String

        var aliases: Set<String> {
            Set(names.values.filter { $0.isEmpty == false })
        }

        func name(preferences: VectorTileLabelLanguagePreferences,
                  glyphCoverage: VectorTileLabelGlyphCoverage) -> String? {
            for candidate in preferences.fallbackChain {
                let code: String
                if candidate.fieldName == "name" {
                    code = "native"
                } else {
                    code = candidate.fieldName.replacingOccurrences(of: "name_", with: "")
                }

                guard let value = names[code],
                      value.isEmpty == false,
                      glyphCoverage.canRender(value) else {
                    continue
                }

                return value
            }

            return names["en"].flatMap { glyphCoverage.canRender($0) ? $0 : nil }
        }

        func isDuplicate(of existingWaterText: Set<String>) -> Bool {
            aliases.isDisjoint(with: existingWaterText) == false
        }
    }

    private func fallbackLowZoomWaterLabels(for tile: Tile) -> [LocalizedFallbackLabel] {
        var labels: [LocalizedFallbackLabel] = [
            LocalizedFallbackLabel(names: [
                "en": "Pacific Ocean",
                "ru": "Тихий океан",
                "fr": "Océan Pacifique",
                "de": "Pazifischer Ozean",
                "es": "Océano Pacífico",
                "it": "Oceano Pacifico",
                "pt": "Oceano Pacífico",
                "tr": "Pasifik Okyanusu"
            ], latitude: 0.0, longitude: -150.0, sortKey: 20, styleClass: "ocean"),
            LocalizedFallbackLabel(names: [
                "en": "Atlantic Ocean",
                "ru": "Атлантический океан",
                "fr": "Océan Atlantique",
                "de": "Atlantischer Ozean",
                "es": "Océano Atlántico",
                "it": "Oceano Atlantico",
                "pt": "Oceano Atlântico",
                "tr": "Atlas Okyanusu"
            ], latitude: 8.0, longitude: -32.0, sortKey: 18, styleClass: "ocean"),
            LocalizedFallbackLabel(names: [
                "en": "Indian Ocean",
                "ru": "Индийский океан",
                "fr": "Océan Indien",
                "de": "Indischer Ozean",
                "es": "Océano Índico",
                "it": "Oceano Indiano",
                "pt": "Oceano Índico",
                "tr": "Hint Okyanusu"
            ], latitude: -18.0, longitude: 80.0, sortKey: 22, styleClass: "ocean"),
            LocalizedFallbackLabel(names: [
                "en": "Arctic Ocean",
                "ru": "Северный Ледовитый океан",
                "fr": "Océan Arctique",
                "de": "Arktischer Ozean",
                "es": "Océano Ártico",
                "it": "Mar Glaciale Artico",
                "pt": "Oceano Ártico",
                "tr": "Arktik Okyanusu"
            ], latitude: 76.0, longitude: 15.0, sortKey: 16, styleClass: "ocean"),
            LocalizedFallbackLabel(names: [
                "en": "Southern Ocean",
                "ru": "Южный океан",
                "fr": "Océan Austral",
                "de": "Südlicher Ozean",
                "es": "Océano Austral",
                "it": "Oceano Australe",
                "pt": "Oceano Antártico",
                "tr": "Güney Okyanusu"
            ], latitude: -56.0, longitude: 25.0, sortKey: 24, styleClass: "ocean")
        ]

        if tile.z == 2 {
            labels.append(LocalizedFallbackLabel(names: [
                "en": "Mediterranean Sea",
                "ru": "Средиземное море",
                "fr": "Mer Méditerranée",
                "de": "Mittelmeer",
                "es": "Mar Mediterráneo",
                "it": "Mar Mediterraneo",
                "pt": "Mar Mediterrâneo",
                "tr": "Akdeniz"
            ], latitude: 35.0, longitude: 18.0, sortKey: 30, styleClass: "sea"))
            labels.append(LocalizedFallbackLabel(names: [
                "en": "Caribbean Sea",
                "ru": "Карибское море",
                "fr": "Mer des Caraïbes",
                "de": "Karibisches Meer",
                "es": "Mar Caribe",
                "it": "Mar dei Caraibi",
                "pt": "Mar do Caribe",
                "tr": "Karayip Denizi"
            ], latitude: 15.0, longitude: -74.0, sortKey: 32, styleClass: "sea"))
            labels.append(LocalizedFallbackLabel(names: [
                "en": "Arabian Sea",
                "ru": "Аравийское море",
                "fr": "Mer d'Arabie",
                "de": "Arabisches Meer",
                "es": "Mar Arábigo",
                "it": "Mar Arabico",
                "pt": "Mar Arábico",
                "tr": "Umman Denizi"
            ], latitude: 15.0, longitude: 64.0, sortKey: 34, styleClass: "sea"))
            labels.append(LocalizedFallbackLabel(names: [
                "en": "Bering Sea",
                "ru": "Берингово море",
                "fr": "Mer de Béring",
                "de": "Beringmeer",
                "es": "Mar de Bering",
                "it": "Mare di Bering",
                "pt": "Mar de Bering",
                "tr": "Bering Denizi"
            ], latitude: 57.0, longitude: -178.0, sortKey: 36, styleClass: "sea"))
        }

        return labels
    }

    private func stringTileValue(_ value: String) -> VectorTile_Tile.Value {
        var tileValue = VectorTile_Tile.Value()
        tileValue.stringValue = value
        return tileValue
    }

    private func tilePoint(forLatitude latitude: Double,
                           longitude: Double,
                           tile: Tile) -> SIMD2<Int16>? {
        let n = pow(2.0, Double(tile.z))
        guard n > 0 else { return nil }

        let wrappedLongitude = ((longitude + 180.0).truncatingRemainder(dividingBy: 360.0) + 360.0).truncatingRemainder(dividingBy: 360.0) - 180.0
        let x = (wrappedLongitude + 180.0) / 360.0 * n

        let clampedLatitude = min(max(latitude, -85.05112878), 85.05112878)
        let latitudeRadians = clampedLatitude * .pi / 180.0
        let y = (1.0 - log(tan(latitudeRadians) + 1.0 / cos(latitudeRadians)) / .pi) * 0.5 * n

        let localX = (x - Double(tile.x)) * 4096.0
        let localY = (y - Double(tile.y)) * 4096.0
        guard localX >= 0.0, localX <= 4096.0, localY >= 0.0, localY <= 4096.0 else {
            return nil
        }

        let roundedX = Int16(max(0, min(4096, Int(localX.rounded()))))
        let roundedY = Int16(max(0, min(4096, Int(localY.rounded()))))
        return SIMD2<Int16>(roundedX, roundedY)
    }

    private func appendFallbackLowZoomWaterLabels(into textLabels: inout [TextLabel], tile: Tile) {
        guard tile.z <= 2 else {
            return
        }

        let existingWaterText = Set(
            textLabels.filter { $0.textStyle.key == 3 || $0.textStyle.key == 4 }
                .map(\.text)
        )

        for fallback in fallbackLowZoomWaterLabels(for: tile) {
            guard let name = fallback.name(preferences: labelLanguagePreferences,
                                           glyphCoverage: glyphCoverage),
                  fallback.isDuplicate(of: existingWaterText) == false,
                  let point = tilePoint(forLatitude: fallback.latitude,
                                        longitude: fallback.longitude,
                                        tile: tile) else {
                continue
            }

            let attributes: [String: VectorTile_Tile.Value] = [
                "class": stringTileValue(fallback.styleClass),
                "type": stringTileValue(fallback.styleClass),
                "name": stringTileValue(name)
            ]

            let style = determineFeatureStyle.makeStyle(data: DetFeatureStyleData(layerName: "natural_label",
                                                                                  properties: attributes,
                                                                                  tile: tile))
            guard let textStyle = style.labelTextStyle else {
                continue
            }

            textLabels.append(TextLabel(text: name,
                                        position: point,
                                        tile: tile,
                                        featureId: 0,
                                        hasFeatureId: false,
                                        layerName: "natural_label",
                                        sortKey: fallback.sortKey,
                                        collisionPriority: fallback.sortKey,
                                        textStyle: textStyle,
                                        poiIcon: nil))
        }
    }

    
    func readingStage(vectorTile: VectorTile_Tile, tile: Tile) -> ReadingStageResult {
        let parsePolygon = ParsePolygon()
        let parseLine = ParseLine()
        let lineClipper = LineClipper()
        var polygonByStyle: [UInt8: [ParsedPolygon]] = [:]
        var roadPolygonByStyle: [UInt8: [ParsedPolygon]] = [:]
        var orderedRoadPolygons: [OrderedRoadPolygon] = []
        var bridgePolygonByStyle: [UInt8: [ParsedPolygon]] = [:]
        let rawLineByStyle: [UInt8: [ParsedLineRawVertices]] = [:]
        var extrudedByStyle: [UInt8: [ParsedExtrudedMesh]] = [:]
        var styles: [UInt8: FeatureStyle] = [:]
        var roadStyles: [UInt8: FeatureStyle] = [:]
        var bridgeStyles: [UInt8: FeatureStyle] = [:]
        var textLabels: [TextLabel] = []
        var roadTextLabels: [RoadTextLabel] = []
        var roadPolygonSequence = 0
        var buildingExtrusionCandidates: [BuildingExtrusionCandidate] = []
        var layerTimings: [TileParseLayerTiming] = []
        
        for layer in vectorTile.layers {
            let layerStart = DispatchTime.now().uptimeNanoseconds
            let layerName = layer.name
            let buildingPartIds = layerName == "building" ? collectBuildingPartIds(layer: layer) : []
            let buildingPartFootprintSignatures = layerName == "building"
                ? collectBuildingPartFootprintSignatures(layer: layer)
                : []
            let highZoomRoadSharedPointCounts = Self.isSeparateRoadLayer(layerName)
                && tile.z >= config.style.flatSeparateRoadRenderingMinimumZoom
                ? buildHighZoomRoadSharedPointCounts(layer: layer, tile: tile)
                : [:]
            for feature in layer.features {
                let attributes = decodeAttributes(feature: feature, layer: layer)
                
                let detStyleData = DetFeatureStyleData(
                    layerName: layerName,
                    properties: attributes,
                    tile: tile
                )
                let usesSeparateRoadRendering = Self.isSeparateRoadLayer(layerName)
                    && tile.z >= config.style.flatSeparateRoadRenderingMinimumZoom

                let style = determineFeatureStyle.makeStyle(data: detStyleData)
                let styleKey = style.key
                if styleKey == 0 {
                    // none defineded style
                    continue
                }
                if feature.type != .linestring || usesSeparateRoadRendering == false {
                    switch style.linePlacement {
                    case .ground:
                        if styles[styleKey] == nil {
                            styles[styleKey] = style
                        }
                    case .bridgeOverlay:
                        if bridgeStyles[styleKey] == nil {
                            bridgeStyles[styleKey] = style
                        }
                    }
                }
                
                
                if feature.type == .polygon {
                    let geometry: [UInt32] = feature.geometry
                    let polygons = normalize(decodePolygon.decode(geometry: geometry), layer: layer)
                    let shouldSplitComplexOceanHoles = layerName == "ocean"
                        && polygons.contains { $0.interiorRings.count >= Self.complexOceanHoleSplitThreshold }
                    let extrudeFlag = attributes["extrude"].flatMap(parseBoolValue)
                    let isBuildingPart = isTruthy(attributes["building:part"])
                    let buildingId = buildingIdentifier(attributes: attributes, featureId: feature.id)
                    let hasParts = buildingPartIds.contains(buildingId)
                    // buildingFootprintSignature -> canonicalRotation is O(n^2) in ring
                    // vertices; only building-part dedup needs it. Skip it entirely when
                    // there are no part signatures to match (always the case for
                    // non-building layers), so large landcover/water polygons don't pay
                    // the quadratic cost. Result is unchanged: an empty set never matches.
                    let matchesPartFootprint = isBuildingPart == false
                        && buildingPartFootprintSignatures.isEmpty == false
                        && polygons.contains { polygon in
                            guard let signature = buildingFootprintSignature(for: polygon) else {
                                return false
                            }
                            return buildingPartFootprintSignatures.contains(signature)
                        }
                    let locationValue = attributes["location"]?.stringValue.lowercased() ?? ""
                    let isUnderground = isTruthy(attributes["underground"])
                        || locationValue.contains("underground")
                        || locationValue.contains("subterranean")
                        || locationValue.contains("tunnel")
                        || locationValue.contains("underwater")
                    // `extrude` is the Mapbox convention (present, "true"); the
                    // OpenMapTiles building layer has no such field (it drives height
                    // from render_height and hides 3D via hide_3d). Extrude when the
                    // flag is true OR absent, and suppress only when explicitly false
                    // or hide_3d is set - preserving Mapbox behaviour, enabling OMT.
                    let shouldExtrude = style.usesExtrusion
                        && (extrudeFlag != false)
                        && !isTruthy(attributes["hide_3d"])
                        && !isUnderground
                        && !matchesPartFootprint
                        && !(hasParts && !isBuildingPart)
                    let extrusion = shouldExtrude
                        ? extrusionHeights(attributes: attributes, tileZoom: tile.z, style: style)
                        : nil
                    
                    for polygon in polygons {
                        if shouldSplitComplexOceanHoles,
                           appendComplexOceanPolygon(polygon,
                                                     style: style,
                                                     polygonByStyle: &polygonByStyle,
                                                     styles: &styles,
                                                     parsePolygon: parsePolygon,
                                                     tile: tile) {
                            continue
                        }

                        guard let parsedGeometry = parsePolygon.parseGeometry(polygon: polygon,
                                                                              tileExtent: Float(tileExtent)) else {
                            continue
                        }
                        switch style.linePlacement {
                        case .ground:
                            polygonByStyle[styleKey, default: []].append(parsedGeometry.parsedPolygon)
                        case .bridgeOverlay:
                            bridgePolygonByStyle[styleKey, default: []].append(parsedGeometry.parsedPolygon)
                        }
                        
                        if let extrusion,
                           extrusion.top > extrusion.base,
                           let footprintSignature = buildingFootprintSignature(for: polygon) {
                            buildingExtrusionCandidates.append(
                                BuildingExtrusionCandidate(styleKey: styleKey,
                                                           buildingId: buildingId,
                                                           footprintSignature: footprintSignature,
                                                           clippedExterior: parsedGeometry.clipped.exterior,
                                                           clippedInteriors: parsedGeometry.clipped.interiors,
                                                           roof: parsedGeometry.parsedPolygon,
                                                           roofInfo: extrusion.roof,
                                                           baseHeight: extrusion.base,
                                                           topHeight: extrusion.top)
                            )
                        }
                    }
                    
                } else if feature.type == .linestring {
                    let geometry: [UInt32] = feature.geometry
                    let lineRenderPasses = style.resolvedLineRenderPasses.filter { $0.parseGeometryStyleData.lineWidth > 0 }
                    if lineRenderPasses.isEmpty {
                        continue
                    }

                    let labelText = labelTextResolver.resolveText(properties: attributes,
                                                                  preferences: labelLanguagePreferences,
                                                                  additionalKeys: labelProviderProfile.labelTextKeys)
                    let roadLabelPass = lineRenderPasses.first { $0.includeRoadLabelPath }
                    let roadLabelStyle = style.roadLabelTextStyle
                    let roadStructure = roadStructureKind(attributes: attributes)
                    let roadLayer = roadLayerValue(attributes: attributes)
                    let roadClassPriority = style.roadClassPriority
                    let sharedRoadPadding = Float(
                        lineRenderPasses.reduce(0.0) { partial, pass in
                            max(partial, pass.parseGeometryStyleData.lineWidth * 0.5)
                        }
                    )
                    let lines = normalize(decodeLine.decode(geometry: geometry), layer: layer)
                    for line in lines {
                        let exactClippedFragments = lineClipper.clip(line: line, tileExtent: Float(tileExtent))
                        guard exactClippedFragments.isEmpty == false else {
                            continue
                        }
                        let sharedPaddedFragments = usesSeparateRoadRendering
                            ? lineClipper.clip(line: line,
                                               tileExtent: Float(tileExtent),
                                               padding: sharedRoadPadding)
                            : []

                        for lineRenderPass in lineRenderPasses {
                            if style.roadDecorationKind == .zebraCrossing, roadStructure == .tunnel {
                                continue
                            }

                            let passStyle = FeatureStyle(
                                key: lineRenderPass.key,
                                color: lineRenderPass.color,
                                lowZoomFadeMask: lineRenderPass.lowZoomFadeMask,
                                parseGeometryStyleData: lineRenderPass.parseGeometryStyleData,
                                includeRoadLabelPath: lineRenderPass.includeRoadLabelPath,
                                linePlacement: lineRenderPass.placement,
                                roadClassPriority: roadClassPriority,
                                roadLabelTextStyle: roadLabelStyle,
                                roadDecorationKind: style.roadDecorationKind
                            )
                            if usesSeparateRoadRendering {
                                if roadStyles[lineRenderPass.key] == nil {
                                    roadStyles[lineRenderPass.key] = passStyle
                                }
                            } else {
                                switch lineRenderPass.placement {
                                case .ground:
                                    if styles[lineRenderPass.key] == nil {
                                        styles[lineRenderPass.key] = passStyle
                                    }
                                case .bridgeOverlay:
                                    if bridgeStyles[lineRenderPass.key] == nil {
                                        bridgeStyles[lineRenderPass.key] = passStyle
                                    }
                                }
                            }

                            if shouldRenderCrosswalkZebra(style: style,
                                                          usesSeparateRoadRendering: usesSeparateRoadRendering,
                                                          roadStructure: roadStructure) {
                                for fragment in exactClippedFragments {
                                    let zebraPolygons = crosswalkZebraBuilder.buildPolygons(
                                        points: fragment.points,
                                        zoneWidth: Float(lineRenderPass.parseGeometryStyleData.lineWidth),
                                        tileExtent: Float(tileExtent)
                                    )
                                    for zebraPolygon in zebraPolygons {
                                        roadPolygonByStyle[lineRenderPass.key, default: []].append(zebraPolygon)
                                        orderedRoadPolygons.append(
                                            OrderedRoadPolygon(
                                                polygon: zebraPolygon,
                                                styleKey: lineRenderPass.key,
                                                structureKind: roadStructure,
                                                layer: roadLayer,
                                                classPriority: roadClassPriority,
                                                passRole: lineRenderPass.roadPassRole,
                                                sequence: roadPolygonSequence
                                            )
                                        )
                                        roadPolygonSequence += 1
                                    }
                                }
                                continue
                            }

                            if usesSeparateRoadRendering,
                               style.roadDecorationKind == .onewayArrow,
                               lineRenderPass.roadPassRole == .detail {
                                for fragment in exactClippedFragments {
                                    let arrowPolygons = roadDirectionArrowBuilder.buildPolygons(
                                        points: fragment.points,
                                        lineWidth: Float(lineRenderPass.parseGeometryStyleData.lineWidth),
                                        tileExtent: Float(tileExtent)
                                    )
                                    for arrowPolygon in arrowPolygons {
                                        roadPolygonByStyle[lineRenderPass.key, default: []].append(arrowPolygon)
                                        orderedRoadPolygons.append(
                                            OrderedRoadPolygon(
                                                polygon: arrowPolygon,
                                                styleKey: lineRenderPass.key,
                                                structureKind: roadStructure,
                                                layer: roadLayer,
                                                classPriority: roadClassPriority,
                                                passRole: lineRenderPass.roadPassRole,
                                                sequence: roadPolygonSequence
                                            )
                                        )
                                        roadPolygonSequence += 1
                                    }
                                }
                                continue
                            }

                            let padding = Float(lineRenderPass.parseGeometryStyleData.lineWidth * 0.5)
                            let paddedFragments = usesSeparateRoadRendering
                                ? sharedPaddedFragments
                                : lineClipper.clip(line: line,
                                                   tileExtent: Float(tileExtent),
                                                   padding: padding)

                            for fragment in paddedFragments {
                                let renderFragments = renderFragments(for: fragment,
                                                                      styleData: lineRenderPass.parseGeometryStyleData)

                                for renderFragment in renderFragments {
                                    let startConnected = usesSeparateRoadRendering
                                        && renderFragment.points.first.map {
                                            (highZoomRoadSharedPointCounts[RoadConnectionPointKey(point: $0)] ?? 0) > 1
                                        } == true
                                    let endConnected = usesSeparateRoadRendering
                                        && renderFragment.points.last.map {
                                            (highZoomRoadSharedPointCounts[RoadConnectionPointKey(point: $0)] ?? 0) > 1
                                        } == true
                                    let startBoundaryContinuation = usesSeparateRoadRendering
                                        && isRoadBoundaryContinuationEndpoint(renderFragment.points.first)
                                    let endBoundaryContinuation = usesSeparateRoadRendering
                                        && isRoadBoundaryContinuationEndpoint(renderFragment.points.last)
                                    let startContinuation = usesSeparateRoadRendering
                                        && (renderFragment.startClipped || startBoundaryContinuation)
                                    let endContinuation = usesSeparateRoadRendering
                                        && (renderFragment.endClipped || endBoundaryContinuation)
                                    let shouldExtendStart = usesSeparateRoadRendering
                                        && ((renderFragment.startClipped && shouldExtendClippedRoadEndpoint(renderFragment.points.first))
                                            || (startBoundaryContinuation && shouldExtendRoadBoundaryEndpoint(renderFragment.points.first)))
                                    let shouldExtendEnd = usesSeparateRoadRendering
                                        && ((renderFragment.endClipped && shouldExtendClippedRoadEndpoint(renderFragment.points.last))
                                            || (endBoundaryContinuation && shouldExtendRoadBoundaryEndpoint(renderFragment.points.last)))

                                    let startCapRound = lineRenderPass.parseGeometryStyleData.lineCapRound
                                        && startContinuation == false
                                        && startConnected == false
                                        && renderFragment.points.first.map { isPointStrictlyInsideTile($0) } == true
                                    let endCapRound = lineRenderPass.parseGeometryStyleData.lineCapRound
                                        && endContinuation == false
                                        && endConnected == false
                                        && renderFragment.points.last.map { isPointStrictlyInsideTile($0) } == true

                                    if let linePolygon = parseLine.parse(points: renderFragment.points,
                                                                         width: lineRenderPass.parseGeometryStyleData.lineWidth,
                                                                         tileExtent: Float(tileExtent),
                                                                         startCapRound: startCapRound,
                                                                         endCapRound: endCapRound,
                                                                         lineJoinRound: lineRenderPass.parseGeometryStyleData.lineJoinRound,
                                                                         extendClippedStart: shouldExtendStart,
                                                                         extendClippedEnd: shouldExtendEnd,
                                                                         clipPadding: usesSeparateRoadRendering ? sharedRoadPadding : 0,
                                                                         clipGeometryToTileBounds: usesSeparateRoadRendering == false) {
                                        if usesSeparateRoadRendering {
                                            roadPolygonByStyle[lineRenderPass.key, default: []].append(linePolygon)
                                            orderedRoadPolygons.append(
                                                OrderedRoadPolygon(
                                                    polygon: linePolygon,
                                                    styleKey: lineRenderPass.key,
                                                    structureKind: roadStructure,
                                                    layer: roadLayer,
                                                    classPriority: roadClassPriority,
                                                    passRole: lineRenderPass.roadPassRole,
                                                    sequence: roadPolygonSequence
                                                )
                                            )
                                            roadPolygonSequence += 1
                                        } else {
                                            switch lineRenderPass.placement {
                                            case .ground:
                                                polygonByStyle[lineRenderPass.key, default: []].append(linePolygon)
                                            case .bridgeOverlay:
                                                bridgePolygonByStyle[lineRenderPass.key, default: []].append(linePolygon)
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        if roadLabelPass != nil,
                           let labelText,
                           let roadLabelStyle {
                            for fragment in exactClippedFragments {
                                guard shouldIncludeRoadLabelFragment(fragment) else {
                                    continue
                                }
                                let path = linePath(points: fragment.points)
                                if path.count >= 2 {
                                    roadTextLabels.append(RoadTextLabel(text: labelText,
                                                                        path: path,
                                                                        tile: tile,
                                                                        featureId: feature.id,
                                                                        hasFeatureId: feature.hasID,
                                                                        layerName: layerName,
                                                                        textStyle: roadLabelStyle))
                                }
                            }
                        }
                    }
                } else if feature.type == .point {
                    guard let labelTextStyle = style.labelTextStyle else { continue }
                    let points = normalize(decodePoint.decode(geometry: feature.geometry), layer: layer)
                    let featureID = feature.hasID ? feature.id : nil
                    let poiIcon = poiSpriteResolver.resolve(attributes: attributes, layerName: layerName)
                    for point in points where isPointInsideTile(point) {
                        let anchor = SIMD2(Int16(point.x), Int16(point.y))
                        let labelFeature = VectorTileLabelFeature(providerID: labelProviderProfile.providerID,
                                                                  tile: tile,
                                                                  layerName: layerName,
                                                                  featureID: featureID,
                                                                  anchor: anchor,
                                                                  properties: attributes)
                        guard let decision = labelDecisionEngine.makePointLabelDecision(feature: labelFeature,
                                                                                        style: labelTextStyle,
                                                                                        poiIcon: poiIcon) else {
                            continue
                        }
                        textLabels.append(TextLabel(text: decision.text,
                                                    position: anchor,
                                                    key: decision.identity.runtimeKey,
                                                    sortKey: decision.priority.visibilityRank,
                                                    collisionPriority: decision.priority.collisionRank,
                                                    textStyle: decision.style,
                                                    poiIcon: decision.poiIcon))
                    }
                }
            }
            let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - layerStart
            layerTimings.append(TileParseLayerTiming(layerName: layerName,
                                                     duration: TimeInterval(elapsedNanoseconds) / 1_000_000_000.0))

        }

        appendFallbackLowZoomWaterLabels(into: &textLabels, tile: tile)
        
        addBackground(polygonByStyle: &polygonByStyle, styles: &styles)
        if config.tiles.parsing.addTestBorders { addBorder(polygonByStyle: &polygonByStyle, styles: &styles, borderWidth: 1) }

        let resolvedBuildingExtrusions = resolveExteriorBuildingExtrusions(buildingExtrusionCandidates)
        for candidate in resolvedBuildingExtrusions {
            if let extrudedMesh = buildExtrudedMesh(clippedExterior: candidate.clippedExterior,
                                                    clippedInteriors: candidate.clippedInteriors,
                                                    roof: candidate.roof,
                                                    roofInfo: candidate.roofInfo,
                                                    baseHeight: candidate.baseHeight,
                                                    topHeight: candidate.topHeight,
                                                    tileExtent: Float(tileExtent)) {
                extrudedByStyle[candidate.styleKey, default: []].append(extrudedMesh)
            }
        }
        
        return ReadingStageResult(
            polygonByStyle: polygonByStyle.filter { $0.value.isEmpty == false },
            roadPolygonByStyle: roadPolygonByStyle.filter { $0.value.isEmpty == false },
            orderedRoadPolygons: orderedRoadPolygons,
            bridgePolygonByStyle: bridgePolygonByStyle.filter { $0.value.isEmpty == false },
            rawLineByStyle: rawLineByStyle.filter { $0.value.isEmpty == false },
            extrudedByStyle: extrudedByStyle.filter { $0.value.isEmpty == false },
            styles: styles,
            roadStyles: roadStyles,
            bridgeStyles: bridgeStyles,
            textLabels: textLabels,
            roadTextLabels: roadTextLabels,
            layerTimings: layerTimings
        )
    }

    private func unifyPolygonLayer(polygonByStyle: [UInt8: [ParsedPolygon]],
                                   stylesByKey: [UInt8: FeatureStyle]) -> (drawing: DrawingPolygonBytes,
                                                                           styles: [TilePolygonStyle],
                                                                           overviewStyleMasks: [Float]) {
        var unifiedVertices: [TilePipeline.VertexIn] = []
        var unifiedIndices: [UInt32] = []
        var currentVertexOffset: UInt32 = 0
        var styles: [TilePolygonStyle] = []
        var overviewStyleMasks: [Float] = []

        let totalPolygonVertexCount = polygonByStyle.values.reduce(0) { partial, polygons in
            partial + polygons.reduce(0) { polygonPartial, polygon in
                polygonPartial + polygon.vertices.count
            }
        }
        let totalPolygonIndexCount = polygonByStyle.values.reduce(0) { partial, polygons in
            partial + polygons.reduce(0) { polygonPartial, polygon in
                polygonPartial + polygon.indices.count
            }
        }

        unifiedVertices.reserveCapacity(totalPolygonVertexCount)
        unifiedIndices.reserveCapacity(totalPolygonIndexCount)

        let styleKeys = polygonByStyle.keys
            .filter { polygonByStyle[$0]?.isEmpty == false }
            .sorted()
        var styleIndexByKey: [UInt8: UInt8] = [:]
        styleIndexByKey.reserveCapacity(styleKeys.count)
        styles.reserveCapacity(styleKeys.count)
        overviewStyleMasks.reserveCapacity(styleKeys.count)
        for (index, styleKey) in styleKeys.enumerated() {
            if index > Int(UInt8.max) {
                assertionFailure("Too many styles for tile pipeline.")
                continue
            }
            styleIndexByKey[styleKey] = UInt8(index)
        }

        for styleKey in styleKeys {
            let styleBufferIndex = styleIndexByKey[styleKey] ?? 0
            if let polygons = polygonByStyle[styleKey] {
                for polygon in polygons {
                    for position in polygon.vertices {
                        unifiedVertices.append(TilePipeline.VertexIn(position: position, styleIndex: styleBufferIndex))
                    }
                    for index in polygon.indices {
                        unifiedIndices.append(index + currentVertexOffset)
                    }
                    currentVertexOffset += UInt32(polygon.vertices.count)
                }
            }

            if let style = stylesByKey[styleKey] {
                styles.append(TilePolygonStyle(color: style.color))
                overviewStyleMasks.append(style.lowZoomFadeMask)
            }
        }

        return (drawing: DrawingPolygonBytes(vertices: unifiedVertices,
                                             indices: unifiedIndices),
                styles: styles,
                overviewStyleMasks: overviewStyleMasks)
    }

    private func unifyOrderedRoadLayer(orderedRoadPolygons: [OrderedRoadPolygon],
                                       stylesByKey: [UInt8: FeatureStyle]) -> (drawing: DrawingPolygonBytes,
                                                                               styles: [TilePolygonStyle],
                                                                               overviewStyleMasks: [Float]) {
        var unifiedVertices: [TilePipeline.VertexIn] = []
        var unifiedIndices: [UInt32] = []
        var currentVertexOffset: UInt32 = 0
        var styles: [TilePolygonStyle] = []
        var overviewStyleMasks: [Float] = []

        let totalPolygonVertexCount = orderedRoadPolygons.reduce(0) { partial, polygon in
            partial + polygon.polygon.vertices.count
        }
        let totalPolygonIndexCount = orderedRoadPolygons.reduce(0) { partial, polygon in
            partial + polygon.polygon.indices.count
        }

        unifiedVertices.reserveCapacity(totalPolygonVertexCount)
        unifiedIndices.reserveCapacity(totalPolygonIndexCount)

        let styleKeys = Array(Set(orderedRoadPolygons.map(\.styleKey))).sorted()
        var styleIndexByKey: [UInt8: UInt8] = [:]
        styleIndexByKey.reserveCapacity(styleKeys.count)
        styles.reserveCapacity(styleKeys.count)
        overviewStyleMasks.reserveCapacity(styleKeys.count)

        for (index, styleKey) in styleKeys.enumerated() {
            if index > Int(UInt8.max) {
                assertionFailure("Too many styles for tile pipeline.")
                continue
            }
            styleIndexByKey[styleKey] = UInt8(index)
            if let style = stylesByKey[styleKey] {
                styles.append(TilePolygonStyle(color: style.color))
                overviewStyleMasks.append(style.lowZoomFadeMask)
            }
        }

        for orderedPolygon in orderedRoadPolygons.sorted(by: OrderedRoadPolygon.sort) {
            let styleBufferIndex = styleIndexByKey[orderedPolygon.styleKey] ?? 0
            for position in orderedPolygon.polygon.vertices {
                unifiedVertices.append(TilePipeline.VertexIn(position: position, styleIndex: styleBufferIndex))
            }
            for index in orderedPolygon.polygon.indices {
                unifiedIndices.append(index + currentVertexOffset)
            }
            currentVertexOffset += UInt32(orderedPolygon.polygon.vertices.count)
        }

        return (drawing: DrawingPolygonBytes(vertices: unifiedVertices,
                                             indices: unifiedIndices),
                styles: styles,
                overviewStyleMasks: overviewStyleMasks)
    }

    private func makeDrawingGeometryLayer(
        drawing: DrawingPolygonBytes,
        styles: [TilePolygonStyle],
        overviewStyleMasks: [Float]
    ) -> DrawingGeometryLayer {
        DrawingGeometryLayer(drawing: drawing,
                             styles: styles,
                             overviewStyleMasks: overviewStyleMasks)
    }

    private func makeEmptyDrawingGeometryLayer() -> DrawingGeometryLayer {
        makeDrawingGeometryLayer(drawing: DrawingPolygonBytes(vertices: [], indices: []),
                                 styles: [],
                                 overviewStyleMasks: [])
    }
    
    func unificationStage(readingStageResult: ReadingStageResult) -> UnificationStageResult {
        let polygonByStyle = readingStageResult.polygonByStyle
        let roadPolygonByStyle = readingStageResult.roadPolygonByStyle
        let bridgePolygonByStyle = readingStageResult.bridgePolygonByStyle
        _ = readingStageResult.rawLineByStyle
        let extrudedByStyle = readingStageResult.extrudedByStyle

        let groundLayer = unifyPolygonLayer(polygonByStyle: polygonByStyle,
                                            stylesByKey: readingStageResult.styles)
        let emptyRoadLayer = makeEmptyDrawingGeometryLayer()
        let roadPhases: RoadStructureBuckets<RoadGeometryPhases<DrawingGeometryLayer>>
        if readingStageResult.orderedRoadPolygons.isEmpty {
            let unifiedRoadLayer = unifyPolygonLayer(polygonByStyle: roadPolygonByStyle,
                                                     stylesByKey: readingStageResult.roadStyles)
            roadPhases = RoadStructureBuckets(
                tunnel: RoadGeometryPhases(shadow: emptyRoadLayer,
                                           casing: emptyRoadLayer,
                                           fill: emptyRoadLayer,
                                           detail: emptyRoadLayer,
                                           overlay: emptyRoadLayer),
                ground: RoadGeometryPhases(shadow: emptyRoadLayer,
                                           casing: emptyRoadLayer,
                                           fill: makeDrawingGeometryLayer(drawing: unifiedRoadLayer.drawing,
                                                                         styles: unifiedRoadLayer.styles,
                                                                         overviewStyleMasks: unifiedRoadLayer.overviewStyleMasks),
                                           detail: emptyRoadLayer,
                                           overlay: emptyRoadLayer),
                bridge: RoadGeometryPhases(shadow: emptyRoadLayer,
                                           casing: emptyRoadLayer,
                                           fill: emptyRoadLayer,
                                           detail: emptyRoadLayer,
                                           overlay: emptyRoadLayer)
            )
        } else {
            let orderedRoadPolygons = readingStageResult.orderedRoadPolygons
            func makeStructurePhases(_ structureKind: RoadStructureKind) -> RoadGeometryPhases<DrawingGeometryLayer> {
                func makePhase(_ role: RoadPassRole) -> DrawingGeometryLayer {
                    let layer = unifyOrderedRoadLayer(
                        orderedRoadPolygons: orderedRoadPolygons.filter {
                            $0.structureKind == structureKind && $0.passRole == role
                        },
                        stylesByKey: readingStageResult.roadStyles
                    )
                    return makeDrawingGeometryLayer(drawing: layer.drawing,
                                                    styles: layer.styles,
                                                    overviewStyleMasks: layer.overviewStyleMasks)
                }

                return RoadGeometryPhases(shadow: makePhase(.shadow),
                                          casing: makePhase(.casing),
                                          fill: makePhase(.fill),
                                          detail: makePhase(.detail),
                                          overlay: makePhase(.overlay))
            }

            roadPhases = RoadStructureBuckets(
                tunnel: makeStructurePhases(.tunnel),
                ground: makeStructurePhases(.ground),
                bridge: makeStructurePhases(.bridge)
            )
        }
        let bridgeLayer = unifyPolygonLayer(polygonByStyle: bridgePolygonByStyle,
                                            stylesByKey: readingStageResult.bridgeStyles)
        var unifiedExtrudedVertices: [ExtrudedVertexIn] = []
        var unifiedExtrudedIndices: [UInt32] = []
        var currentExtrudedVertexOffset: UInt32 = 0
        var nextGlobalSurfaceID: UInt32 = 1
        let totalExtrudedVertexCount = extrudedByStyle.values.reduce(0) { partial, meshes in
            partial + meshes.reduce(0) { meshPartial, mesh in
                meshPartial + mesh.vertices.count
            }
        }
        let totalExtrudedIndexCount = extrudedByStyle.values.reduce(0) { partial, meshes in
            partial + meshes.reduce(0) { meshPartial, mesh in
                meshPartial + mesh.indices.count
            }
        }

        unifiedExtrudedVertices.reserveCapacity(totalExtrudedVertexCount)
        unifiedExtrudedIndices.reserveCapacity(totalExtrudedIndexCount)

        let styleKeys = extrudedByStyle.keys
            .filter { extrudedByStyle[$0]?.isEmpty == false }
            .sorted()
        var styleIndexByKey: [UInt8: UInt8] = [:]
        var extrudedStyles: [TilePolygonStyle] = []
        styleIndexByKey.reserveCapacity(styleKeys.count)
        extrudedStyles.reserveCapacity(styleKeys.count)
        for (index, styleKey) in styleKeys.enumerated() {
            if index > Int(UInt8.max) {
                assertionFailure("Too many styles for tile pipeline.")
                continue
            }
            styleIndexByKey[styleKey] = UInt8(index)
            if let style = readingStageResult.styles[styleKey] {
                extrudedStyles.append(TilePolygonStyle(color: style.color))
            }
        }

        for styleKey in styleKeys {
            let styleBufferIndex = styleIndexByKey[styleKey] ?? 0
            if let extrudedMeshes = extrudedByStyle[styleKey] {
                for extrudedMesh in extrudedMeshes {
                    var surfaceIDRemap: [UInt32: UInt32] = [:]
                    surfaceIDRemap.reserveCapacity(8)
                    for vertex in extrudedMesh.vertices {
                        let globalSurfaceID: UInt32
                        if let existingSurfaceID = surfaceIDRemap[vertex.surfaceID] {
                            globalSurfaceID = existingSurfaceID
                        } else {
                            globalSurfaceID = nextGlobalSurfaceID
                            nextGlobalSurfaceID &+= 1
                            surfaceIDRemap[vertex.surfaceID] = globalSurfaceID
                        }
                        unifiedExtrudedVertices.append(ExtrudedVertexIn(position: vertex.position,
                                                                        normal: vertex.normal,
                                                                        styleIndex: styleBufferIndex,
                                                                        surfaceID: globalSurfaceID))
                    }
                    for index in extrudedMesh.indices {
                        unifiedExtrudedIndices.append(index + currentExtrudedVertexOffset)
                    }
                    currentExtrudedVertexOffset += UInt32(extrudedMesh.vertices.count)
                }
            }
        }
        
        return UnificationStageResult(
            drawingPolygon: groundLayer.drawing,
            drawingRoadPhases: roadPhases,
            drawingBridgePolygon: bridgeLayer.drawing,
            drawingExtruded: DrawingExtrudedBytes(
                vertices: unifiedExtrudedVertices,
                indices: unifiedExtrudedIndices,
                styles: extrudedStyles
            ),
            styles: groundLayer.styles,
            overviewStyleMasks: groundLayer.overviewStyleMasks,
            bridgeStyles: bridgeLayer.styles,
            bridgeOverviewStyleMasks: bridgeLayer.overviewStyleMasks
        )
    }
}
