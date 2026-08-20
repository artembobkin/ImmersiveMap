// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import MetalKit


class TileMvtParser {
    private static let dashEpsilon: Float = 0.0001
    private static let minClippedRoadLabelFragmentLength: Float = 256.0
    static let complexOceanHoleSplitThreshold = 64
    let determineFeatureStyle               : DetermineFeatureStyle
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
        let decodedTile = try MvtTileDecoder.decode(data: mvtData)
        let readingStageResult = readingStage(decodedTile: decodedTile, tile: tile)
        let unificationResult = unificationStage(readingStageResult: readingStageResult)

        return ParsedTile(
            drawingPolygon: unificationResult.drawingPolygon,
            drawingRoadPhases: unificationResult.drawingRoadPhases,
            drawingBridgePolygon: unificationResult.drawingBridgePolygon,
            drawingExtruded: unificationResult.drawingExtruded,
            styles: unificationResult.styles,
            overviewStyleMasks: unificationResult.overviewStyleMasks,
            lineStyles: unificationResult.lineStyles,
            bridgeStyles: unificationResult.bridgeStyles,
            bridgeOverviewStyleMasks: unificationResult.bridgeOverviewStyleMasks,
            bridgeLineStyles: unificationResult.bridgeLineStyles,
            tile: tile,
            textLabels: readingStageResult.textLabels,
            roadTextLabels: readingStageResult.roadTextLabels,
            parseLayerTimings: readingStageResult.layerTimings
        )
    }

    private func floatPoints(_ line: LineString) -> [SIMD2<Float>] {
        line.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
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

    /// Styles state a class priority per road; from this value up the road is
    /// part of the automobile network and draws in the tier above the
    /// pedestrian one. The built-in style puts service roads at 45 and paths
    /// at 35 with rail between; a custom style with a priority lands in the
    /// tier its number implies.
    static let automobileRoadClassPriorityFloor = 45

    /// The class from which a road makes a junction for the paint on another
    /// one: `minor`, the lowest class that is a street rather than a way onto
    /// a plot. A service driveway, a parking aisle and a footway meeting an
    /// avenue leave its markings running, because on the ground they do.
    static let markingJunctionClassPriorityFloor = 50

    /// Shifts a polyline sideways by `offset` tile units (positive to the left
    /// of travel), with mitred corners so the shifted line stays parallel to
    /// the original; the miter is capped so a hairpin does not shoot the
    /// corner off to infinity. Zero offset returns the input.
    static func offsetPolyline(_ points: [SIMD2<Float>], by offset: Float) -> [SIMD2<Float>] {
        guard abs(offset) > 1e-6, points.count >= 2 else { return points }
        var normals: [SIMD2<Float>] = []
        normals.reserveCapacity(points.count - 1)
        for index in 0..<(points.count - 1) {
            let direction = points[index + 1] - points[index]
            let length = simd_length(direction)
            normals.append(length > 1e-6 ? SIMD2<Float>(-direction.y, direction.x) / length : SIMD2<Float>(0, 0))
        }
        var shifted: [SIMD2<Float>] = []
        shifted.reserveCapacity(points.count)
        for index in 0..<points.count {
            let before = index > 0 ? normals[index - 1] : normals[0]
            let after = index < normals.count ? normals[index] : normals[normals.count - 1]
            var miter = before + after
            let miterLength = simd_length(miter)
            if miterLength > 1e-6 {
                miter /= miterLength
                // Projection of the unit miter onto one normal gives the
                // cosine of the half angle; the miter length is its inverse,
                // capped at 2 (a 60 degree turn) so sharp corners stay sane.
                let cosine = max(simd_dot(miter, after), 0.5)
                shifted.append(points[index] + miter * (offset / cosine))
            } else {
                shifted.append(points[index] + after * offset)
            }
        }
        return shifted
    }

    /// Pulls a polyline back from its ends by `inset` tile units along its own
    /// path, consuming whole leading or trailing segments when the inset
    /// exceeds them. Returns nil when the line is shorter than the insets it
    /// is asked for: a stub of paint with no room for a dash is no paint.
    static func insetLineEnds(_ points: [SIMD2<Float>],
                              inset: Float,
                              insetStart: Bool,
                              insetEnd: Bool) -> [SIMD2<Float>]? {
        insetLineEnds(points,
                      startInset: insetStart ? inset : 0,
                      endInset: insetEnd ? inset : 0)
    }

    /// The same, with an inset chosen per end: the paint stops half of the
    /// road it meets short of the junction, and the two ends of one piece
    /// usually meet different roads.
    static func insetLineEnds(_ points: [SIMD2<Float>],
                              startInset: Float,
                              endInset: Float) -> [SIMD2<Float>]? {
        guard startInset > 0 || endInset > 0, points.count >= 2 else {
            return points
        }
        var working = points
        func trim(_ reversed: Bool) -> Bool {
            var remaining = reversed ? endInset : startInset
            guard remaining > 0 else { return true }
            var path = reversed ? Array(working.reversed()) : working
            while path.count >= 2 {
                let segment = path[1] - path[0]
                let length = simd_length(segment)
                if length > remaining {
                    path[0] = path[0] + segment / length * remaining
                    working = reversed ? Array(path.reversed()) : path
                    return true
                }
                remaining -= length
                path.removeFirst()
            }
            return false
        }
        if trim(false) == false {
            return nil
        }
        if trim(true) == false {
            return nil
        }
        return working.count >= 2 ? working : nil
    }

    /// The leading and trailing stretch of a line, each `length` tile units
    /// long: the solid approach a marking wears where it runs up to a
    /// junction. Ends the caller marks as continuations get no stretch, since
    /// a tile seam is not an approach to anything.
    static func endSegments(_ points: [SIMD2<Float>],
                            length: Float,
                            atStart: Bool,
                            atEnd: Bool) -> [(points: [SIMD2<Float>], isHead: Bool)] {
        guard length > 0, points.count >= 2 else { return [] }

        func leading(_ path: [SIMD2<Float>]) -> [SIMD2<Float>]? {
            var remaining = length
            var result: [SIMD2<Float>] = [path[0]]
            for index in 1..<path.count {
                let segment = path[index] - path[index - 1]
                let segmentLength = simd_length(segment)
                if segmentLength >= remaining {
                    result.append(path[index - 1] + segment / max(segmentLength, .leastNormalMagnitude) * remaining)
                    return result.count >= 2 ? result : nil
                }
                remaining -= segmentLength
                result.append(path[index])
            }
            // Shorter than the stretch asked for: the whole piece is approach.
            return result.count >= 2 ? result : nil
        }

        var segments: [(points: [SIMD2<Float>], isHead: Bool)] = []
        if atStart, let head = leading(points) {
            segments.append((points: head, isHead: true))
        }
        if atEnd, let tail = leading(Array(points.reversed())) {
            segments.append((points: tail.reversed(), isHead: false))
        }
        return segments
    }

    func roadStructureKind(attributes: [String: VectorTile_Tile.Value]) -> RoadStructureKind {
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

    func roadLayerValue(attributes: [String: VectorTile_Tile.Value]) -> Int {
        attributes["layer"].flatMap(parseIntValue) ?? 0
    }

    /// A road line decoded, converted, and exact-clipped once: the pre-pass
    /// counts shared endpoints from it and the main pass tessellates from it,
    /// so the geometry work is not repeated per pass.
    private struct PreparedRoadLine {
        let points: [SIMD2<Float>]
        let exactFragments: [ClippedLineFragment]
    }

    private struct HighZoomRoadPrecomputation {
        let sharedPointCounts: [RoadConnectionPointKey: Int]
        /// How many distinct STREETS touch each point, counted over the
        /// classes that make a junction for the paint down a carriageway:
        /// `minor` and above.
        ///
        /// A street is its name, so the two sides of a seam the stitcher
        /// could not close (a piece whose lane count or oneway differs)
        /// count once between them: the paint runs through, because on the
        /// ground the street does. A footpath crossing the line is not a
        /// junction either, and neither is a service driveway or a parking
        /// aisle meeting a street: paint does not break for a gateway.
        let automobilePointCounts: [RoadConnectionPointKey: Int]
        /// Half the widest carriageway that meets each point, in tile units.
        /// The gap a marking leaves at a junction is the room the crossing
        /// road takes, not the room its own road takes: a lane line running
        /// into a six-lane avenue has to clear the avenue.
        let junctionHalfWidths: [RoadConnectionPointKey: Float]
        let linesByFeatureIndex: [[PreparedRoadLine]]
        /// Carriageway-surface polygons (junction areas) of the layer, as
        /// converted rings, with the road class priority each one draws at.
        /// A ribbon of the same or a lower class that runs inside one of them
        /// is clipped away there: the surface owns that ground.
        let surfaceAreas: [RoadSurfaceArea]

        static let empty = HighZoomRoadPrecomputation(sharedPointCounts: [:],
                                                      automobilePointCounts: [:],
                                                      junctionHalfWidths: [:],
                                                      linesByFeatureIndex: [],
                                                      surfaceAreas: [])
    }

    struct RoadSurfaceArea {
        let exterior: [SIMD2<Float>]
        let classPriority: Int
        let bounds: (min: SIMD2<Float>, max: SIMD2<Float>)
    }

    private func buildHighZoomRoadPrecomputation(layer: MvtDecodedLayer,
                                                 featureStyles: [FeatureStyle],
                                                 featureAttributes: [[String: VectorTile_Tile.Value]],
                                                 lineClipper: LineClipper,
                                                 data: Data) -> HighZoomRoadPrecomputation {
        var rawLinesByFeatureIndex = Array(repeating: [[SIMD2<Float>]](), count: layer.features.count)
        var surfaceAreas: [RoadSurfaceArea] = []

        // One payload mapping for the whole pre-pass instead of one per
        // feature geometry.
        data.withUnsafeBytes { bytes in
            for (featureIndex, feature) in layer.features.enumerated() {
                let style = featureStyles[featureIndex]
                guard style.key != 0 else {
                    continue
                }
                switch feature.type {
                case .linestring:
                    let lines = normalize(MvtGeometryDecoder.decodeLines(feature.geometry, in: bytes), layer: layer)
                    rawLinesByFeatureIndex[featureIndex] = lines.map(floatPoints)
                case .polygon where style.isRoadSurfaceArea:
                    let polygons = normalize(MvtGeometryDecoder.decodePolygons(feature.geometry, in: bytes), layer: layer)
                    for polygon in polygons where polygon.exteriorRing.count >= 3 {
                        let ring = polygon.exteriorRing.map {
                            SIMD2<Float>(Float($0.x), Float(tileExtent) - Float($0.y))
                        }
                        var lower = ring[0]
                        var upper = ring[0]
                        for point in ring {
                            lower = simd_min(lower, point)
                            upper = simd_max(upper, point)
                        }
                        surfaceAreas.append(RoadSurfaceArea(exterior: ring,
                                                            classPriority: style.roadClassPriority,
                                                            bounds: (lower, upper)))
                    }
                default:
                    break
                }
            }
        }

        // A ribbon that runs inside a carriageway surface of its own or a
        // higher class is redundant there: the surface is that ground, drawn
        // as one polygon with one kerb. Left in place, the ribbon's fill paints
        // over the surface's kerb along the side it follows (a kerb on one
        // side of the street and none on the other), and its own kerbs draw
        // inside the surface. The parts inside are clipped away; the parts
        // outside keep drawing and end flush at the surface's edge.
        if surfaceAreas.isEmpty == false {
            for featureIndex in 0..<rawLinesByFeatureIndex.count where rawLinesByFeatureIndex[featureIndex].isEmpty == false {
                let priority = featureStyles[featureIndex].roadClassPriority
                let owners = surfaceAreas.filter { $0.classPriority >= priority }
                guard owners.isEmpty == false else { continue }
                rawLinesByFeatureIndex[featureIndex] = rawLinesByFeatureIndex[featureIndex].flatMap {
                    RoadSurfaceClipper.clip(polyline: $0, outside: owners)
                }
            }
        }

        // Pieces of one street that the tiles ship cut (OSM way boundaries a
        // merge did not close, or cuts the tiler made) are stitched end to
        // end before tessellation, so the street is one ribbon with no seam
        // where the pieces met: no pair of caps, no kerb across the join.
        // Stitching needs a street identity on the geometry (`name`, with the
        // drawing attributes equal); without it nothing is stitched and the
        // pieces draw as they arrive.
        let stitched = RoadStreetStitcher.stitch(linesByFeatureIndex: rawLinesByFeatureIndex,
                                                 featureAttributes: featureAttributes,
                                                 featureStyles: featureStyles)

        var pointCounts: [RoadConnectionPointKey: Int] = [:]
        // Distinct streets per point, not occurrences and not features: a
        // street arrives cut into pieces the stitcher could not join, and
        // both sides of such a seam carry the same point. Counting it twice
        // there calls the seam a junction, breaks the paint and lights a
        // solid approach on a street that simply continues. Streets are told
        // apart by name; a piece without one answers only for itself.
        var streetIdentifiers: [String: Int] = [:]
        var streetIdentifierByFeature = [Int](repeating: -1, count: layer.features.count)
        for index in 0..<layer.features.count {
            let name = featureAttributes[index]["name"]?.stringValue ?? ""
            if name.isEmpty {
                streetIdentifierByFeature[index] = -1 - index
            } else {
                let next = streetIdentifiers.count
                streetIdentifierByFeature[index] = streetIdentifiers[name] ?? next
                if streetIdentifiers[name] == nil { streetIdentifiers[name] = next }
            }
        }
        var automobileStreetsAtPoint: [RoadConnectionPointKey: Set<Int>] = [:]
        var junctionHalfWidths: [RoadConnectionPointKey: Float] = [:]
        var linesByFeatureIndex = Array(repeating: [PreparedRoadLine](), count: layer.features.count)
        for (featureIndex, lines) in stitched.enumerated() where lines.isEmpty == false {
            var preparedLines: [PreparedRoadLine] = []
            preparedLines.reserveCapacity(lines.count)
            let isJunctionMaking = featureStyles[featureIndex].roadClassPriority >= Self.markingJunctionClassPriorityFloor
            // The carriageway this feature draws at: the style's own geometry
            // is the fill ribbon, so half of it is how far the road reaches
            // from its centreline.
            let halfWidth = Float(featureStyles[featureIndex].parseGeometryStyleData.lineWidth) * 0.5
            for points in lines {
                let fragments = lineClipper.clip(points: points, tileExtent: Float(tileExtent))
                for fragment in fragments {
                    for point in fragment.points {
                        let key = RoadConnectionPointKey(point: point)
                        pointCounts[key, default: 0] += 1
                        if isJunctionMaking {
                            automobileStreetsAtPoint[key, default: []].insert(streetIdentifierByFeature[featureIndex])
                            junctionHalfWidths[key] = max(junctionHalfWidths[key] ?? 0, halfWidth)
                        }
                    }
                }
                preparedLines.append(PreparedRoadLine(points: points, exactFragments: fragments))
            }
            linesByFeatureIndex[featureIndex] = preparedLines
        }
        let automobilePointCounts = automobileStreetsAtPoint.mapValues(\.count)

        return HighZoomRoadPrecomputation(sharedPointCounts: pointCounts,
                                          automobilePointCounts: automobilePointCounts,
                                          junctionHalfWidths: junctionHalfWidths,
                                          linesByFeatureIndex: linesByFeatureIndex,
                                          surfaceAreas: surfaceAreas)
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
                    // The chain carries both source spellings of a language
                    // field (`name_en` and `name:en`); either strips to the
                    // same language code here.
                    code = candidate.fieldName
                        .replacingOccurrences(of: "name_", with: "")
                        .replacingOccurrences(of: "name:", with: "")
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
                                        poiIcon: nil,
                                        minCameraZoom: style.labelMinCameraZoom))
        }
    }

    
    func readingStage(decodedTile: MvtDecodedTile, tile: Tile) -> ReadingStageResult {
        let mvtData = decodedTile.sourceData
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
        
        for layer in decodedTile.layers {
            let layerStart = DispatchTime.now().uptimeNanoseconds
            let layerName = layer.name
            let usesSeparateRoadRendering = Self.isSeparateRoadLayer(layerName)
                && tile.z >= config.style.flatSeparateRoadRenderingMinimumZoom

            // Attributes and style resolve exactly once per feature here; the
            // building and road pre-passes below share them instead of
            // re-decoding the tag table per pass.
            var featureAttributes: [[String: VectorTile_Tile.Value]] = []
            featureAttributes.reserveCapacity(layer.features.count)
            var featureStyles: [FeatureStyle] = []
            featureStyles.reserveCapacity(layer.features.count)
            mvtData.withUnsafeBytes { bytes in
                for feature in layer.features {
                    let attributes = decodeAttributes(feature: feature, layer: layer, bytes: bytes)
                    featureAttributes.append(attributes)
                    featureStyles.append(determineFeatureStyle.makeStyle(data: DetFeatureStyleData(
                        layerName: layerName,
                        properties: attributes,
                        tile: tile
                    )))
                }
            }

            let buildingPartInfo = layerName == "building"
                ? collectBuildingPartInfo(layer: layer, featureAttributes: featureAttributes, data: mvtData)
                : (partIds: Set<UInt64>(), footprintSignatures: Set<BuildingFootprintSignature>())
            let buildingPartIds = buildingPartInfo.partIds
            let buildingPartFootprintSignatures = buildingPartInfo.footprintSignatures
            let highZoomRoads = usesSeparateRoadRendering
                ? buildHighZoomRoadPrecomputation(layer: layer,
                                                  featureStyles: featureStyles,
                                                  featureAttributes: featureAttributes,
                                                  lineClipper: lineClipper,
                                                  data: mvtData)
                : .empty
            let highZoomRoadSharedPointCounts = highZoomRoads.sharedPointCounts
            let highZoomAutomobilePointCounts = highZoomRoads.automobilePointCounts
            let highZoomJunctionHalfWidths = highZoomRoads.junctionHalfWidths
            for (featureIndex, feature) in layer.features.enumerated() {
                let attributes = featureAttributes[featureIndex]
                let style = featureStyles[featureIndex]
                let styleKey = style.key
                if styleKey == 0 {
                    // none defineded style
                    continue
                }
                // A line style (boundary) that arrived as area geometry is not
                // filled - otherwise, for example, Indian reservations in the
                // `boundary` layer are drawn as solid polygons.
                if feature.type == .polygon, style.suppressPolygonFill {
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
                    let polygons = normalize(MvtGeometryDecoder.decodePolygons(feature.geometry, in: mvtData),
                                             layer: layer)
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
                        if style.isRoadSurfaceArea, usesSeparateRoadRendering {
                            // A carriageway surface (junction area) joins the
                            // road phases instead of the ground: its fill pass
                            // is the triangulated polygon, its casing pass the
                            // outline tessellated as a closed kerb. Sorted among
                            // the roads by class, so the surface covers the
                            // kerbs of the ribbons that run into it.
                            appendRoadSurfaceArea(parsedGeometry: parsedGeometry,
                                                  clippedExterior: parsedGeometry.clipped.exterior,
                                                  clippedInteriors: parsedGeometry.clipped.interiors,
                                                  style: style,
                                                  attributes: attributes,
                                                  roadStyles: &roadStyles,
                                                  roadPolygonByStyle: &roadPolygonByStyle,
                                                  orderedRoadPolygons: &orderedRoadPolygons,
                                                  roadPolygonSequence: &roadPolygonSequence,
                                                  parseLine: parseLine)
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
                            // Same conversion as ParsePolygon.convertRing, so
                            // the raw ring shares exact coordinates with the
                            // clipped one on uncut edges.
                            let rawExterior = polygon.exteriorRing.map {
                                SIMD2<Float>(Float($0.x), Float(tileExtent) - Float($0.y))
                            }
                            buildingExtrusionCandidates.append(
                                BuildingExtrusionCandidate(styleKey: styleKey,
                                                           buildingId: buildingId,
                                                           footprintSignature: footprintSignature,
                                                           clippedExterior: parsedGeometry.clipped.exterior,
                                                           clippedInteriors: parsedGeometry.clipped.interiors,
                                                           rawExterior: rawExterior,
                                                           hasRawInteriorRings: polygon.interiorRings.contains { $0.count >= 3 },
                                                           roof: parsedGeometry.parsedPolygon,
                                                           roofInfo: extrusion.roof,
                                                           baseHeight: extrusion.base,
                                                           topHeight: extrusion.top)
                            )
                        }
                    }
                    
                } else if feature.type == .linestring {
                    let lineRenderPasses = style.resolvedLineRenderPasses.filter { $0.parseGeometryStyleData.lineWidth > 0 }
                    if lineRenderPasses.isEmpty {
                        continue
                    }

                    let labelText = labelTextResolver.resolveText(properties: attributes,
                                                                  preferences: labelLanguagePreferences,
                                                                  additionalKeys: labelProviderProfile.labelTextKeys)
                    let roadLabelPass = lineRenderPasses.first { $0.includeRoadLabelPath }
                    let roadLabelStyle = style.roadLabelTextStyle
                    let roadClassPriority = style.roadClassPriority
                    let physicalStructure = roadStructureKind(attributes: attributes)
                    // On the ground the automobile network draws as its own
                    // tier above the pedestrian one, so a path ending against
                    // an avenue never lies over its kerb. The class priority
                    // the style states is the tier line: drive tiers sit at
                    // 45 and above, footways, tracks and rail below.
                    let roadStructure: RoadStructureKind = physicalStructure == .ground
                        && roadClassPriority >= Self.automobileRoadClassPriorityFloor
                        ? .automobileGround
                        : physicalStructure
                    let roadLayer = roadLayerValue(attributes: attributes)
                    let sharedRoadPadding = Float(
                        lineRenderPasses.reduce(0.0) { partial, pass in
                            max(partial, pass.parseGeometryStyleData.lineWidth * 0.5)
                        }
                    )
                    let preparedLines: [PreparedRoadLine]
                    if usesSeparateRoadRendering {
                        preparedLines = highZoomRoads.linesByFeatureIndex[featureIndex]
                    } else {
                        let lines = normalize(MvtGeometryDecoder.decodeLines(feature.geometry, in: mvtData),
                                              layer: layer)
                        var converted: [PreparedRoadLine] = []
                        converted.reserveCapacity(lines.count)
                        for line in lines {
                            let points = floatPoints(line)
                            converted.append(PreparedRoadLine(points: points,
                                                              exactFragments: lineClipper.clip(points: points,
                                                                                               tileExtent: Float(tileExtent))))
                        }
                        preparedLines = converted
                    }
                    for preparedLine in preparedLines {
                        let linePoints = preparedLine.points
                        let exactClippedFragments = preparedLine.exactFragments
                        guard exactClippedFragments.isEmpty == false else {
                            continue
                        }
                        let sharedPaddedFragments = usesSeparateRoadRendering
                            ? lineClipper.clip(points: linePoints,
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
                                streetColor: lineRenderPass.streetColor,
                                lowZoomFadeMask: lineRenderPass.lowZoomFadeMask,
                                lineWidthPoints: lineRenderPass.lineWidthPoints,
                                dashLengthPoints: lineRenderPass.dashLengthPoints,
                                dashGapPoints: lineRenderPass.dashGapPoints,
                                dashInTileUnits: lineRenderPass.dashInTileUnits,
                                minimumWidthPoints: lineRenderPass.minimumWidthPoints,
                                maximumWidthPoints: lineRenderPass.maximumWidthPoints,
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
                                : lineClipper.clip(points: linePoints,
                                                   tileExtent: Float(tileExtent),
                                                   padding: padding)

                            for fragment in paddedFragments {
                                // Paint stops at a junction, as it does on the
                                // ground: a street's centre line does not run
                                // across the street it meets. The tiles ship a
                                // through street as one line with the junctions
                                // as interior vertices, so the inset at the two
                                // ends is not enough; the line is cut at every
                                // interior point another carriageway touches,
                                // and each piece is inset from its own new
                                // ends. Only marking passes are cut: the
                                // carriageway and its kerb run through.
                                let junctionSplit = lineRenderPass.parseGeometryStyleData.endInset > 0
                                    && usesSeparateRoadRendering
                                    ? Self.splitAtJunctions(fragment: fragment,
                                                            automobilePointCounts: highZoomAutomobilePointCounts)
                                    : [fragment]
                                let renderFragments = junctionSplit.flatMap { piece in
                                    self.renderFragments(for: piece,
                                                         styleData: lineRenderPass.parseGeometryStyleData)
                                }

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

                                    // A free end is a genuine end of the line: not a cut that
                                    // continues into a neighboring tile, not a shared road
                                    // junction, and not sitting on the tile boundary. Free ends
                                    // are the ones that may be capped or feathered; every other
                                    // cut must stay hard so it meets adjacent geometry flush.
                                    let startFree = startContinuation == false
                                        && startConnected == false
                                        && renderFragment.points.first.map { isPointStrictlyInsideTile($0) } == true
                                    let endFree = endContinuation == false
                                        && endConnected == false
                                        && renderFragment.points.last.map { isPointStrictlyInsideTile($0) } == true
                                    let startCapRound = lineRenderPass.parseGeometryStyleData.lineCapRound && startFree
                                    let endCapRound = lineRenderPass.parseGeometryStyleData.lineCapRound && endFree

                                    // An inset pulls the line back from a genuine end or a
                                    // junction; a tile-seam cut keeps its point so the line
                                    // continues flush in the neighbour. The room a marking
                                    // leaves at a junction is the widest carriageway that
                                    // meets it, not its own: a lane line running into a
                                    // six-lane avenue has to clear the avenue.
                                    let styleData = lineRenderPass.parseGeometryStyleData
                                    func junctionInset(_ point: SIMD2<Float>?, isContinuation: Bool) -> Float {
                                        guard styleData.endInset > 0, isContinuation == false, let point else { return 0 }
                                        return max(Float(styleData.endInset),
                                                   highZoomJunctionHalfWidths[RoadConnectionPointKey(point: point)] ?? 0)
                                    }
                                    func isJunction(_ point: SIMD2<Float>?, isContinuation: Bool) -> Bool {
                                        guard isContinuation == false, let point else { return false }
                                        return (highZoomAutomobilePointCounts[RoadConnectionPointKey(point: point)] ?? 0) > 1
                                    }
                                    let startIsJunction = isJunction(renderFragment.points.first, isContinuation: startContinuation)
                                    let endIsJunction = isJunction(renderFragment.points.last, isContinuation: endContinuation)
                                    // Paint runs up to a junction solid, the way it does on
                                    // the ground: the dashed body stops short of the approach
                                    // and the solid pass draws exactly that stretch, so the
                                    // two meet without overlapping.
                                    let approachLength = Float(styleData.junctionApproachLength)
                                    var startInset = junctionInset(renderFragment.points.first, isContinuation: startContinuation)
                                    var endInset = junctionInset(renderFragment.points.last, isContinuation: endContinuation)
                                    if styleData.drawsJunctionApproachOnly == false {
                                        if startIsJunction { startInset += approachLength }
                                        if endIsJunction { endInset += approachLength }
                                    }
                                    let insetPoints = Self.insetLineEnds(renderFragment.points,
                                                                         startInset: startInset,
                                                                         endInset: endInset)
                                    guard let insetPoints else {
                                        continue
                                    }
                                    let drawnPieces: [(points: [SIMD2<Float>], isHead: Bool)]
                                    if styleData.drawsJunctionApproachOnly {
                                        drawnPieces = Self.endSegments(insetPoints,
                                                                       length: approachLength,
                                                                       atStart: startIsJunction,
                                                                       atEnd: endIsJunction)
                                    } else {
                                        drawnPieces = [(points: insetPoints, isHead: true)]
                                    }
                                    for drawnPiece in drawnPieces {
                                    // An approach stretch meets the dashed body at its inner
                                    // end, which must stay a hard cut; only the end that is
                                    // the line's own keeps the fragment's feathering.
                                    let pieceFeatherStart = styleData.drawsJunctionApproachOnly
                                        ? (drawnPiece.isHead && startFree)
                                        : startFree
                                    let pieceFeatherEnd = styleData.drawsJunctionApproachOnly
                                        ? (drawnPiece.isHead == false && endFree)
                                        : endFree
                                    let passPoints = Self.offsetPolyline(
                                        drawnPiece.points,
                                        by: Float(styleData.lateralOffset)
                                    )

                                    if let linePolygon = parseLine.parse(points: passPoints,
                                                                         width: lineRenderPass.parseGeometryStyleData.lineWidth,
                                                                         tileExtent: Float(tileExtent),
                                                                         startCapRound: startCapRound && pieceFeatherStart,
                                                                         endCapRound: endCapRound && pieceFeatherEnd,
                                                                         lineJoinRound: styleData.lineJoinRound,
                                                                         featherStart: pieceFeatherStart,
                                                                         featherEnd: pieceFeatherEnd,
                                                                         emitsArcLength: lineRenderPass.dashLengthPoints > 0,
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
                    let points = normalize(MvtGeometryDecoder.decodePoints(feature.geometry, in: mvtData),
                                           layer: layer)
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
                                                    poiIcon: decision.poiIcon,
                                                    minCameraZoom: style.labelMinCameraZoom,
                                                    detailCategory: decision.detailCategory))
                    }
                }
            }
            let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - layerStart
            layerTimings.append(TileParseLayerTiming(layerName: layerName,
                                                     duration: TimeInterval(elapsedNanoseconds) / 1_000_000_000.0))

        }

        appendFallbackLowZoomWaterLabels(into: &textLabels, tile: tile)
        
        addBackground(polygonByStyle: &polygonByStyle, styles: &styles, tile: tile)
        if config.tiles.parsing.addTestBorders { addBorder(polygonByStyle: &polygonByStyle, styles: &styles, borderWidth: 1) }

        let resolvedBuildingExtrusions = resolveExteriorBuildingExtrusions(buildingExtrusionCandidates)
        for candidate in resolvedBuildingExtrusions {
            if let extrudedMesh = buildExtrudedMesh(clippedExterior: candidate.clippedExterior,
                                                    clippedInteriors: candidate.clippedInteriors,
                                                    rawExterior: candidate.rawExterior,
                                                    hasRawInteriorRings: candidate.hasRawInteriorRings,
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

    /// Cuts a line at every interior point where another carriageway meets
    /// it, so a pass that insets its ends (the paint down a road) stops short
    /// of each junction instead of running through it.
    ///
    /// A point is a junction when more than one drive-tier feature touches it.
    /// The endpoints of the fragment are left alone: they are already ends,
    /// and whether they are a genuine end, a tile seam or a junction is
    /// decided by the caller, which knows about clipping.
    static func splitAtJunctions(fragment: ClippedLineFragment,
                                 automobilePointCounts: [RoadConnectionPointKey: Int]) -> [ClippedLineFragment] {
        let points = fragment.points
        guard points.count > 2 else { return [fragment] }

        var pieces: [ClippedLineFragment] = []
        var current: [SIMD2<Float>] = [points[0]]
        for index in 1..<points.count {
            current.append(points[index])
            let isInterior = index < points.count - 1
            guard isInterior,
                  (automobilePointCounts[RoadConnectionPointKey(point: points[index])] ?? 0) > 1 else {
                continue
            }
            // The piece ends here, and the next one starts at the same point:
            // both are genuine ends, so both get the inset.
            pieces.append(ClippedLineFragment(points: current,
                                              startClipped: pieces.isEmpty ? fragment.startClipped : false,
                                              endClipped: false))
            current = [points[index]]
        }
        guard pieces.isEmpty == false else { return [fragment] }
        if current.count >= 2 {
            pieces.append(ClippedLineFragment(points: current,
                                              startClipped: false,
                                              endClipped: fragment.endClipped))
        }
        return pieces
    }

    /// Bulk-appends one tessellated polygon into the unified vertex/index
    /// streams. The buffers were sized exactly by the caller, so the writes
    /// are raw pointer stores without per-append growth or uniqueness checks.
    private static func appendPolygon(_ polygon: ParsedPolygon,
                                      styleBufferIndex: UInt8,
                                      vertices: inout UnsafeMutableBufferPointer<TileVertexIn>,
                                      indices: inout UnsafeMutableBufferPointer<UInt32>,
                                      vertexCount: inout Int,
                                      indexCount: inout Int) {
        let vertexOffset = UInt32(vertexCount)
        let hasLineAttributes = polygon.lineDistances.count == polygon.vertices.count
            && polygon.lineParameters.count == polygon.vertices.count
        for (index, position) in polygon.vertices.enumerated() {
            // Attribute-less polygons default to the saturated line interior
            // (see TileVertexIn), so decoration polygons that share a line
            // style render fully covered.
            vertices.initializeElement(at: vertexCount,
                                       to: TileVertexIn(position: position,
                                                        styleIndex: styleBufferIndex,
                                                        lineDistance: hasLineAttributes ? polygon.lineDistances[index] : 0,
                                                        lineParameter: hasLineAttributes ? polygon.lineParameters[index] : Int16.max))
            vertexCount += 1
        }
        for index in polygon.indices {
            indices.initializeElement(at: indexCount, to: index &+ vertexOffset)
            indexCount += 1
        }
    }

    private func unifyPolygonLayer(polygonByStyle: [UInt8: [ParsedPolygon]],
                                   stylesByKey: [UInt8: FeatureStyle]) -> (drawing: DrawingPolygonBytes,
                                                                           styles: [TilePolygonStyle],
                                                                           overviewStyleMasks: [Float],
                                                                           lineStyles: [TileLineStyle]) {
        var styles: [TilePolygonStyle] = []
        var overviewStyleMasks: [Float] = []
        var lineStyles: [TileLineStyle] = []

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

        var unifiedIndices: [UInt32] = []
        let unifiedVertices = [TileVertexIn](
            unsafeUninitializedCapacity: totalPolygonVertexCount
        ) { vertexBuffer, initializedVertexCount in
            unifiedIndices = [UInt32](
                unsafeUninitializedCapacity: totalPolygonIndexCount
            ) { indexBuffer, initializedIndexCount in
                var vertexCount = 0
                var indexCount = 0
                for styleKey in styleKeys {
                    let styleBufferIndex = styleIndexByKey[styleKey] ?? 0
                    guard let polygons = polygonByStyle[styleKey] else { continue }
                    for polygon in polygons {
                        Self.appendPolygon(polygon,
                                           styleBufferIndex: styleBufferIndex,
                                           vertices: &vertexBuffer,
                                           indices: &indexBuffer,
                                           vertexCount: &vertexCount,
                                           indexCount: &indexCount)
                    }
                }
                initializedVertexCount = vertexCount
                initializedIndexCount = indexCount
            }
        }

        for styleKey in styleKeys {
            if let style = stylesByKey[styleKey] {
                styles.append(TilePolygonStyle(color: style.color, streetColor: style.streetColor))
                overviewStyleMasks.append(style.lowZoomFadeMask)
                lineStyles.append(Self.makeTileLineStyle(from: style))
            }
        }

        return (drawing: DrawingPolygonBytes(vertices: unifiedVertices,
                                             indices: unifiedIndices),
                styles: styles,
                overviewStyleMasks: overviewStyleMasks,
                lineStyles: lineStyles)
    }

    /// The GPU-side line parameters of one style. The edge threshold derives
    /// from the tessellated width and the tessellator's feather constant, so
    /// the two stay one definition; a style with no line width keeps a zero
    /// threshold, which is what tells the shader to skip line coverage.
    static func makeTileLineStyle(from style: FeatureStyle) -> TileLineStyle {
        let halfWidth = Float(style.parseGeometryStyleData.lineWidth) * 0.5
        let edgeThreshold = halfWidth > 0
            ? halfWidth / (halfWidth + ParseLine.featherTileUnits)
            : 0
        return TileLineStyle(widthPoints: style.lineWidthPoints,
                             dashLengthPoints: style.dashLengthPoints,
                             dashGapPoints: style.dashGapPoints,
                             edgeThreshold: edgeThreshold,
                             minimumWidthPoints: style.minimumWidthPoints,
                             dashInTileUnits: style.dashInTileUnits,
                             maximumWidthPoints: style.maximumWidthPoints)
    }

    /// Expects the polygons already sorted by `OrderedRoadPolygon.sort`; the
    /// caller buckets and sorts once per structure/pass combination.
    private func unifyOrderedRoadLayer(sortedRoadPolygons: [OrderedRoadPolygon],
                                       stylesByKey: [UInt8: FeatureStyle]) -> (drawing: DrawingPolygonBytes,
                                                                               styles: [TilePolygonStyle],
                                                                               overviewStyleMasks: [Float],
                                                                               lineStyles: [TileLineStyle]) {
        var styles: [TilePolygonStyle] = []
        var overviewStyleMasks: [Float] = []
        var lineStyles: [TileLineStyle] = []

        let totalPolygonVertexCount = sortedRoadPolygons.reduce(0) { partial, polygon in
            partial + polygon.polygon.vertices.count
        }
        let totalPolygonIndexCount = sortedRoadPolygons.reduce(0) { partial, polygon in
            partial + polygon.polygon.indices.count
        }

        let styleKeys = Array(Set(sortedRoadPolygons.map(\.styleKey))).sorted()
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
                styles.append(TilePolygonStyle(color: style.color, streetColor: style.streetColor))
                overviewStyleMasks.append(style.lowZoomFadeMask)
                lineStyles.append(Self.makeTileLineStyle(from: style))
            }
        }

        var unifiedIndices: [UInt32] = []
        let unifiedVertices = [TileVertexIn](
            unsafeUninitializedCapacity: totalPolygonVertexCount
        ) { vertexBuffer, initializedVertexCount in
            unifiedIndices = [UInt32](
                unsafeUninitializedCapacity: totalPolygonIndexCount
            ) { indexBuffer, initializedIndexCount in
                var vertexCount = 0
                var indexCount = 0
                for orderedPolygon in sortedRoadPolygons {
                    Self.appendPolygon(orderedPolygon.polygon,
                                       styleBufferIndex: styleIndexByKey[orderedPolygon.styleKey] ?? 0,
                                       vertices: &vertexBuffer,
                                       indices: &indexBuffer,
                                       vertexCount: &vertexCount,
                                       indexCount: &indexCount)
                }
                initializedVertexCount = vertexCount
                initializedIndexCount = indexCount
            }
        }

        return (drawing: DrawingPolygonBytes(vertices: unifiedVertices,
                                             indices: unifiedIndices),
                styles: styles,
                overviewStyleMasks: overviewStyleMasks,
                lineStyles: lineStyles)
    }

    private func makeDrawingGeometryLayer(
        drawing: DrawingPolygonBytes,
        styles: [TilePolygonStyle],
        overviewStyleMasks: [Float],
        lineStyles: [TileLineStyle]
    ) -> DrawingGeometryLayer {
        DrawingGeometryLayer(drawing: drawing,
                             styles: styles,
                             overviewStyleMasks: overviewStyleMasks,
                             lineStyles: lineStyles)
    }

    private func makeEmptyDrawingGeometryLayer() -> DrawingGeometryLayer {
        makeDrawingGeometryLayer(drawing: DrawingPolygonBytes(vertices: [], indices: []),
                                 styles: [],
                                 overviewStyleMasks: [],
                                 lineStyles: [])
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
                                                                         overviewStyleMasks: unifiedRoadLayer.overviewStyleMasks,
                                                                         lineStyles: unifiedRoadLayer.lineStyles),
                                           detail: emptyRoadLayer,
                                           overlay: emptyRoadLayer),
                automobileGround: RoadGeometryPhases(shadow: emptyRoadLayer,
                                                     casing: emptyRoadLayer,
                                                     fill: emptyRoadLayer,
                                                     detail: emptyRoadLayer,
                                                     overlay: emptyRoadLayer),
                bridge: RoadGeometryPhases(shadow: emptyRoadLayer,
                                           casing: emptyRoadLayer,
                                           fill: emptyRoadLayer,
                                           detail: emptyRoadLayer,
                                           overlay: emptyRoadLayer)
            )
        } else {
            // One pass buckets every polygon by structure and pass role; the
            // old shape filtered the full array 15 times.
            let roleCount = RoadPassRole.allCases.count
            var buckets = Array(repeating: [OrderedRoadPolygon](),
                                count: RoadStructureKind.allCases.count * roleCount)
            for orderedPolygon in readingStageResult.orderedRoadPolygons {
                buckets[orderedPolygon.structureKind.rawValue * roleCount + orderedPolygon.passRole.rawValue]
                    .append(orderedPolygon)
            }

            func makeStructurePhases(_ structureKind: RoadStructureKind) -> RoadGeometryPhases<DrawingGeometryLayer> {
                func makePhase(_ role: RoadPassRole) -> DrawingGeometryLayer {
                    let bucket = buckets[structureKind.rawValue * roleCount + role.rawValue]
                    let layer = unifyOrderedRoadLayer(
                        sortedRoadPolygons: bucket.sorted(by: OrderedRoadPolygon.sort),
                        stylesByKey: readingStageResult.roadStyles
                    )
                    return makeDrawingGeometryLayer(drawing: layer.drawing,
                                                    styles: layer.styles,
                                                    overviewStyleMasks: layer.overviewStyleMasks,
                                                    lineStyles: layer.lineStyles)
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
                automobileGround: makeStructurePhases(.automobileGround),
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
                extrudedStyles.append(TilePolygonStyle(color: style.color, streetColor: style.streetColor))
            }
        }

        for styleKey in styleKeys {
            let styleBufferIndex = styleIndexByKey[styleKey] ?? 0
            if let extrudedMeshes = extrudedByStyle[styleKey] {
                for extrudedMesh in extrudedMeshes {
                    // Mesh-local surface IDs are allocated sequentially from 1
                    // and appear in the vertex stream in that order, so the
                    // first-appearance remap the old per-mesh dictionary
                    // produced is exactly a constant offset.
                    let surfaceIDBase = nextGlobalSurfaceID &- 1
                    var maxLocalSurfaceID: UInt32 = 0
                    for vertex in extrudedMesh.vertices {
                        maxLocalSurfaceID = max(maxLocalSurfaceID, vertex.surfaceID)
                        unifiedExtrudedVertices.append(ExtrudedVertexIn(position: vertex.position,
                                                                        normal: vertex.normal,
                                                                        styleIndex: styleBufferIndex,
                                                                        surfaceID: surfaceIDBase &+ vertex.surfaceID))
                    }
                    nextGlobalSurfaceID = surfaceIDBase &+ maxLocalSurfaceID &+ 1
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
            lineStyles: groundLayer.lineStyles,
            bridgeStyles: bridgeLayer.styles,
            bridgeOverviewStyleMasks: bridgeLayer.overviewStyleMasks,
            bridgeLineStyles: bridgeLayer.lineStyles
        )
    }
}
