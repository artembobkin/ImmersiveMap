// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Mvt
import simd

/// Reads a line feature into the ribbons its style's passes draw, the
/// decorations stamped along it (crossings, arrows, bus lane letters, bus
/// stop zigzags), and its road name label.
///
/// On the road layer at street zooms the feature takes the separate-road
/// path: its lines come pre-clipped and stitched from the layer's
/// `RoadLayerPrecomputation`, its ribbons join the road phases sorted by
/// structure and class, paint stops at junctions, and ends that continue
/// into a neighbouring tile or another road stay hard. Every other line (a
/// boundary, a waterway, a road at an overview zoom) draws as ground or
/// bridge geometry clipped to the tile with no junction knowledge.
///
/// Stateless across tiles: the per-tile clipper and tessellator come in as
/// arguments.
struct LineFeatureReader {
    /// A road label on a fragment cut by the tile edge needs this much line
    /// inside the tile, or the name is left to the neighbour.
    private static let minClippedRoadLabelFragmentLength: Float = 256.0

    private let labelDecisions: TileLabelDecisions
    private let labelsEnabled: Bool
    private let crosswalkZebraBuilder = CrosswalkZebraGeometryBuilder()
    private let roadDirectionArrowBuilder = RoadDirectionArrowGeometryBuilder()
    private let busLaneLetterBuilder = BusLaneLetterGeometryBuilder()
    private let busStopZigzagBuilder = BusStopZigzagGeometryBuilder()
    private let tileExtent = Float(TileCoordinateSpace.tileExtentDouble)

    init(labelDecisions: TileLabelDecisions, options: TileParseOptions) {
        self.labelDecisions = labelDecisions
        self.labelsEnabled = options.labelsEnabled
    }

    func read(feature: MvtDecodedFeature,
              featureIndex: Int,
              attributes: [String: MvtValue],
              facts: ImmersiveMapFeatureFacts,
              style: FeatureStyle,
              geometry: TileLayerGeometry,
              layerName: String,
              tile: Tile,
              roads: RoadLayerContext,
              tools: TileParseTools,
              into result: inout ReadingStageResult) {
        // A line or a road; every other style draws no line geometry. A
        // plain line is a road of one fill stroke with no class.
        guard let style = style.roadStyle else {
            return
        }
        let lineRenderPasses = style.orderedPasses.filter { $0.pass.lineGeometry.lineWidth > 0 }
        if lineRenderPasses.isEmpty {
            return
        }
        let usesSeparateRoadRendering = roads.usesSeparateRoadRendering
        let precomputation = roads.precomputation
        let lineClipper = tools.lineClipper

        // Labels off: no road name is resolved or baked. The
        // switch is prepared-cache identity, so a tile prepared
        // without labels never answers a map that wants them.
        let labelText = labelsEnabled
            ? labelDecisions.roadLabelText(label: facts.label)
            : nil
        let roadLabelStyle = style.label
        let road = facts.road ?? .ground
        let roadClassPriority = style.classPriority
        let roadStructure = RoadStructureKind(level: style.level, tier: style.tier)
        let roadLayer = road.layer
        let sharedRoadPadding = Float(
            lineRenderPasses.reduce(0.0) { partial, pass in
                max(partial, pass.pass.lineGeometry.lineWidth * 0.5)
            }
        )
        let preparedLines: [PreparedRoadLine]
        if usesSeparateRoadRendering {
            preparedLines = precomputation.linesByFeatureIndex[featureIndex]
        } else {
            let lines = geometry.lines(of: feature)
            var converted: [PreparedRoadLine] = []
            converted.reserveCapacity(lines.count)
            for line in lines {
                let points = RoadLayerPrecomputation.floatPoints(line)
                converted.append(PreparedRoadLine(points: points,
                                                  exactFragments: lineClipper.clip(points: points,
                                                                                   tileExtent: tileExtent)))
            }
            preparedLines = converted
        }
        // Two tracks of the same feature: the ribbon and its
        // labels draw from lines cut by every carriageway
        // surface, the paint from lines cut only by crossings
        // (see paintLinesByFeatureIndex).
        let paintPreparedLines = usesSeparateRoadRendering
            ? precomputation.paintLinesByFeatureIndex[featureIndex]
            : preparedLines
        let passGroups: [(lines: [PreparedRoadLine], passes: [RoadStyle.Pass], emitsLabels: Bool)] = [
            (preparedLines, lineRenderPasses.filter { $0.role != .detail }, true),
            (paintPreparedLines, lineRenderPasses.filter { $0.role == .detail }, false)
        ]
        for group in passGroups where group.passes.isEmpty == false || group.emitsLabels {
            for preparedLine in group.lines {
                let linePoints = preparedLine.points
                let exactClippedFragments = preparedLine.exactFragments
                guard exactClippedFragments.isEmpty == false else {
                    continue
                }
                let sharedPaddedFragments = usesSeparateRoadRendering
                    ? lineClipper.clip(points: linePoints,
                                       tileExtent: tileExtent,
                                       padding: sharedRoadPadding)
                    : []

                for roadPass in group.passes {
                    let lineRenderPass = roadPass.pass
                    if usesSeparateRoadRendering {
                        result.registerRoadStyle(BakedStyle(pass: lineRenderPass), key: lineRenderPass.key)
                    } else {
                        result.registerStyle(BakedStyle(pass: lineRenderPass), key: lineRenderPass.key, placement: style.placement)
                    }

                    if usesSeparateRoadRendering,
                       appendDecoration(style: style,
                                        pass: roadPass,
                                        fragments: exactClippedFragments,
                                        structure: roadStructure,
                                        layer: roadLayer,
                                        tile: tile,
                                        into: &result) {
                        continue
                    }

                    let padding = Float(lineRenderPass.lineGeometry.lineWidth * 0.5)
                    let paddedFragments = usesSeparateRoadRendering
                        ? sharedPaddedFragments
                        : lineClipper.clip(points: linePoints,
                                           tileExtent: tileExtent,
                                           padding: padding)

                    for fragment in paddedFragments {
                        let renderFragments = RoadDashPattern.fragments(for: fragment,
                                                                        styleData: lineRenderPass.lineGeometry)

                        for renderFragment in renderFragments {
                            let startConnected = usesSeparateRoadRendering
                                && renderFragment.points.first.map {
                                    (precomputation.sharedPointCounts[RoadConnectionPointKey(point: $0)] ?? 0) > 1
                                } == true
                            let endConnected = usesSeparateRoadRendering
                                && renderFragment.points.last.map {
                                    (precomputation.sharedPointCounts[RoadConnectionPointKey(point: $0)] ?? 0) > 1
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
                            let startCapRound = lineRenderPass.lineGeometry.lineCapRound && startFree
                            let endCapRound = lineRenderPass.lineGeometry.lineCapRound && endFree
                            let styleData = lineRenderPass.lineGeometry

                            if let linePolygon = tools.parseLine.parse(points: renderFragment.points,
                                                                       width: lineRenderPass.lineGeometry.lineWidth,
                                                                       tileExtent: tileExtent,
                                                                       startCapRound: startCapRound,
                                                                       endCapRound: endCapRound,
                                                                       lineJoinRound: styleData.lineJoinRound,
                                                                       featherStart: startFree,
                                                                       featherEnd: endFree,
                                                                       emitsArcLength: lineRenderPass.dashLengthPoints > 0,
                                                                       extendClippedStart: shouldExtendStart,
                                                                       extendClippedEnd: shouldExtendEnd,
                                                                       clipPadding: usesSeparateRoadRendering ? sharedRoadPadding : 0,
                                                                       clipGeometryToTileBounds: usesSeparateRoadRendering == false,
                                                                       // A road bucket ribbon of a flat-era tile is
                                                                       // extruded on the GPU to its width on screen; a
                                                                       // sphere-era tile keeps the baked ribbon, which
                                                                       // the grid split and the sphere projection need.
                                                                       deferredExtrusion: usesSeparateRoadRendering
                                                                           && GroundGeometrySubdivider.step(forTileZoom: tile.z) == nil) {
                                if usesSeparateRoadRendering {
                                    result.appendRoad(linePolygon,
                                                      key: lineRenderPass.key,
                                                      structureKind: roadStructure,
                                                      layer: roadLayer,
                                                      classPriority: roadClassPriority,
                                                      passRole: roadPass.role)
                                } else {
                                    result.appendGround(linePolygon, key: lineRenderPass.key, placement: style.placement)
                                }
                            }
                        }
                    }
                }

                if group.emitsLabels,
                   let labelText,
                   let roadLabelStyle {
                    for fragment in exactClippedFragments {
                        guard shouldIncludeRoadLabelFragment(fragment) else {
                            continue
                        }
                        let path = linePath(points: fragment.points)
                        if path.count >= 2 {
                            result.roadTextLabels.append(ParsedRoadTextLabel(text: labelText,
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
        }
    }

    /// The decoration a pass stamps along the feature's exact fragments on
    /// the separate-road path, appended in place: the zebra of a crossing
    /// (under any pass), and under the detail pass the bus lane's letter,
    /// the bus stop's sawtooth and the oneway arrows.
    /// Returns false when the pass draws the plain ribbon instead.
    private func appendDecoration(style: RoadStyle,
                                  pass roadPass: RoadStyle.Pass,
                                  fragments: [ClippedLineFragment],
                                  structure: RoadStructureKind,
                                  layer: Int,
                                  tile: Tile,
                                  into result: inout ReadingStageResult) -> Bool {
        let pass = roadPass.pass
        func append(_ polygons: [ParsedPolygon]) {
            for polygon in polygons {
                result.appendRoad(polygon,
                                  key: pass.key,
                                  structureKind: structure,
                                  layer: layer,
                                  classPriority: style.classPriority,
                                  passRole: roadPass.role)
            }
        }
        switch style.decoration {
        case .zebraCrossing(let zebra):
            for fragment in fragments {
                append(crosswalkZebraBuilder.buildPolygons(
                    points: fragment.points,
                    zoneWidth: Float(pass.lineGeometry.lineWidth),
                    zebra: zebra
                ))
            }
            return true
        case .busLaneLetter(let letter) where roadPass.role == .detail:
            // The bus lane's axis: the letter A stamped along it, from the
            // same polygon path the zebra and the arrows take.
            for fragment in fragments {
                append(busLaneLetterBuilder.buildPolygons(
                    points: fragment.points,
                    unitsPerMetre: ParkingBayGeometryBuilder.tileUnitsPerMetre(tile: tile),
                    letter: letter
                ))
            }
            return true
        case .busStopZigzag(let zigzag) where roadPass.role == .detail:
            // The stop's kerb: the yellow sawtooth, folded from the shipped
            // axis.
            for fragment in fragments {
                append(busStopZigzagBuilder.buildPolygons(
                    points: fragment.points,
                    unitsPerMetre: ParkingBayGeometryBuilder.tileUnitsPerMetre(tile: tile),
                    zigzag: zigzag
                ))
            }
            return true
        case .onewayArrow(let arrow) where roadPass.role == .detail:
            for fragment in fragments {
                append(roadDirectionArrowBuilder.buildPolygons(
                    points: fragment.points,
                    lineWidth: Float(pass.lineGeometry.lineWidth),
                    arrow: arrow
                ))
            }
            return true
        case .none, .busLaneLetter, .busStopZigzag, .onewayArrow, .parkingBays:
            return false
        }
    }

    private func linePath(points: [SIMD2<Float>]) -> [SIMD2<Int16>] {
        points.map { point in
            let clampedX = min(max(point.x, 0.0), tileExtent)
            let clampedY = min(max(point.y, 0.0), tileExtent)
            return SIMD2(Int16(clamping: Int(clampedX.rounded())),
                         Int16(clamping: Int(clampedY.rounded())))
        }
    }

    private func isPointStrictlyInsideTile(_ point: SIMD2<Float>) -> Bool {
        point.x > 0.0 &&
        point.x < tileExtent &&
        point.y > 0.0 &&
        point.y < tileExtent
    }

    private func isRoadBoundaryContinuationEndpoint(_ point: SIMD2<Float>?) -> Bool {
        guard let point else {
            return false
        }
        return LineClipper.isOnTileBoundary(point, tileExtent: tileExtent)
    }

    private func shouldExtendRoadBoundaryEndpoint(_ point: SIMD2<Float>?) -> Bool {
        guard let point else {
            return false
        }

        let epsilon: Float = 0.0001
        return abs(point.x - tileExtent) <= epsilon || abs(point.y - tileExtent) <= epsilon
    }

    private func shouldExtendClippedRoadEndpoint(_ point: SIMD2<Float>?) -> Bool {
        guard let point else {
            return false
        }

        return point.x > tileExtent || point.y > tileExtent
    }

    private func shouldIncludeRoadLabelFragment(_ fragment: ClippedLineFragment) -> Bool {
        guard fragment.points.count >= 2 else {
            return false
        }

        let isEdgeClipped = fragment.startClipped || fragment.endClipped
        guard isEdgeClipped else {
            return true
        }

        return Self.polylineLength(fragment.points) >= Self.minClippedRoadLabelFragmentLength
    }

    /// The length of a polyline in tile units.
    private static func polylineLength(_ points: [SIMD2<Float>]) -> Float {
        guard points.count >= 2 else {
            return 0
        }
        var totalLength: Float = 0
        for index in 1..<points.count {
            totalLength += simd_length(points[index] - points[index - 1])
        }
        return totalLength
    }
}
