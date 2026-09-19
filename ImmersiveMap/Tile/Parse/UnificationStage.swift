// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// The second stage of a parse: packs what the readers accumulated into the
/// tile's streams, one `DrawingGeometryLayer` per bucket, with the style
/// tables the vertices index into. The ground layer is class-split (fills,
/// then ribbons, then the fills' outlines), the roads are bucketed by
/// structure and pass role and sorted, the buildings are one mesh.
enum TileUnificationStage {
    /// Bulk-appends one tessellated polygon into the unified vertex/index
    /// streams. The buffers were sized exactly by the caller, so the writes
    /// are raw pointer stores without per-append growth or uniqueness checks.
    static func appendPolygon(_ polygon: ParsedPolygon,
                              styleBufferIndex: UInt8,
                              vertices: inout UnsafeMutableBufferPointer<TileVertexIn>,
                              indices: inout UnsafeMutableBufferPointer<UInt32>,
                              vertexCount: inout Int,
                              indexCount: inout Int) {
        #if DEBUG
        // The winding contract of every tile triangle (counter-clockwise in
        // render space, see ParsedPolygon.firstClockwiseTriangle) is kept by
        // each emitter; this is the one funnel the ground, bridge and road
        // geometry all pass through, so a new emitter that breaks it fails
        // here in a debug build instead of vanishing under back-face
        // culling on screen.
        if let triangle = ParsedPolygon.firstClockwiseTriangle(vertices: polygon.vertices, indices: polygon.indices) {
            assertionFailure("Tile geometry must be counter-clockwise in render space: triangle \(triangle) of a \(polygon.vertices.count)-vertex polygon is clockwise and back-face culling would drop it")
        }
        #endif
        let vertexOffset = UInt32(vertexCount)
        let hasLineAttributes = polygon.lineDistances.count == polygon.vertices.count
            && polygon.lineParameters.count == polygon.vertices.count
        let hasLineNormals = hasLineAttributes && polygon.lineNormals.count == polygon.vertices.count
        for (index, position) in polygon.vertices.enumerated() {
            // Attribute-less polygons default to the saturated line interior
            // (see TileVertexIn), so decoration polygons that share a line
            // style render fully covered.
            vertices.initializeElement(at: vertexCount,
                                       to: TileVertexIn(position: position,
                                                        styleIndex: styleBufferIndex,
                                                        lineDistance: hasLineAttributes ? polygon.lineDistances[index] : 0,
                                                        lineParameter: hasLineAttributes ? polygon.lineParameters[index] : Int16.max,
                                                        normal: hasLineNormals ? polygon.lineNormals[index] : .zero))
            vertexCount += 1
        }
        for index in polygon.indices {
            indices.initializeElement(at: indexCount, to: index &+ vertexOffset)
            indexCount += 1
        }
    }

    /// - Parameter splitLinesClass: orders the unified indices as three class
    ///   segments, fills first, then line ribbons, then the fills' outlines
    ///   (each by ascending style), and records the boundaries in
    ///   `DrawingPolygonBytes.fillsIndexCount` and `fillOutlinesIndexStart`.
    ///   The sphere's ground passes then draw one class without touching the
    ///   other's vertices; the paint order becomes "every ribbon above every
    ///   fill", which is also how the split flat/morph draws paint. The
    ///   outline segment is a line list the flat drawer alone reads.
    private static func unifyPolygonLayer(polygonByStyle: [UInt8: [ParsedPolygon]],
                                          stylesByKey: [UInt8: BakedStyle],
                                          splitLinesClass: Bool = false) -> (drawing: DrawingPolygonBytes,
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
        // The fill outlines are the split layer's third class segment: the
        // ring edges of every fill whose style asks for them, as a line
        // list over the fill's own vertices (no vertex is added).
        func emitsFillOutline(_ styleKey: UInt8) -> Bool {
            splitLinesClass && stylesByKey[styleKey]?.outlineAntialiasing == true
        }
        let totalPolygonIndexCount = polygonByStyle.reduce(0) { partial, entry in
            let outlines = emitsFillOutline(entry.key)
            return partial + entry.value.reduce(0) { polygonPartial, polygon in
                polygonPartial + polygon.indices.count + (outlines ? polygon.outlineIndices.count : 0)
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
        var fillsIndexCount: Int?
        var fillOutlinesIndexStart: Int?
        let unifiedVertices = [TileVertexIn](
            unsafeUninitializedCapacity: totalPolygonVertexCount
        ) { vertexBuffer, initializedVertexCount in
            unifiedIndices = [UInt32](
                unsafeUninitializedCapacity: totalPolygonIndexCount
            ) { indexBuffer, initializedIndexCount in
                var vertexCount = 0
                var indexCount = 0
                // The fills sweep remembers where each outlined fill's
                // vertices landed, so the outline segment can index them.
                var outlinedFills: [(polygon: ParsedPolygon, vertexOffset: UInt32)] = []
                // One sweep for the unsplit layer; the split layer sweeps
                // twice, fills then ribbons, each in ascending style order.
                let classSweeps: [((ParsedPolygon) -> Bool)] = splitLinesClass
                    ? [{ $0.isLineRibbon == false }, { $0.isLineRibbon }]
                    : [{ _ in true }]
                for (sweep, includesPolygon) in classSweeps.enumerated() {
                    if sweep == 1 {
                        fillsIndexCount = indexCount
                    }
                    for styleKey in styleKeys {
                        let styleBufferIndex = styleIndexByKey[styleKey] ?? 0
                        guard let polygons = polygonByStyle[styleKey] else { continue }
                        let recordsOutline = sweep == 0 && emitsFillOutline(styleKey)
                        for polygon in polygons where includesPolygon(polygon) {
                            if recordsOutline, polygon.outlineIndices.isEmpty == false {
                                outlinedFills.append((polygon, UInt32(vertexCount)))
                            }
                            Self.appendPolygon(polygon,
                                               styleBufferIndex: styleBufferIndex,
                                               vertices: &vertexBuffer,
                                               indices: &indexBuffer,
                                               vertexCount: &vertexCount,
                                               indexCount: &indexCount)
                        }
                    }
                }
                if splitLinesClass {
                    // The third segment: the outlines in the fills' order,
                    // which is ascending style, as index pairs.
                    fillOutlinesIndexStart = indexCount
                    for (polygon, vertexOffset) in outlinedFills {
                        for index in polygon.outlineIndices {
                            indexBuffer.initializeElement(at: indexCount, to: index &+ vertexOffset)
                            indexCount += 1
                        }
                    }
                }
                initializedVertexCount = vertexCount
                initializedIndexCount = indexCount
            }
        }

        for styleKey in styleKeys {
            if let style = stylesByKey[styleKey] {
                styles.append(TilePolygonStyle(color: style.color, farColor: style.farColor))
                overviewStyleMasks.append(style.lowZoomFadeMask)
                lineStyles.append(Self.makeTileLineStyle(from: style.pass))
            }
        }

        return (drawing: DrawingPolygonBytes(vertices: unifiedVertices,
                                             indices: unifiedIndices,
                                             fillsIndexCount: fillsIndexCount,
                                             fillOutlinesIndexStart: fillOutlinesIndexStart),
                styles: styles,
                overviewStyleMasks: overviewStyleMasks,
                lineStyles: lineStyles)
    }

    /// The radius of the circle about the mesh's ground centre that holds
    /// every vertex's ground position, in tile units: half the building's
    /// extent, whatever its shape.
    static func footprintRadius(of mesh: ParsedExtrudedMesh) -> Float {
        guard mesh.vertices.isEmpty == false else { return 0 }
        var lower = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var upper = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for vertex in mesh.vertices {
            let ground = SIMD2<Float>(vertex.position.x, vertex.position.y)
            lower = simd_min(lower, ground)
            upper = simd_max(upper, ground)
        }
        let centre = (lower + upper) * 0.5
        var radius: Float = 0
        for vertex in mesh.vertices {
            radius = max(radius, simd_length(SIMD2<Float>(vertex.position.x, vertex.position.y) - centre))
        }
        return radius
    }

    /// The GPU-side line parameters of one style. The edge threshold derives
    /// from the tessellated width and the tessellator's feather constant, so
    /// the two stay one definition; a style with no line width keeps a zero
    /// threshold, which is what tells the shader to skip line coverage.
    static func makeTileLineStyle(from pass: LinePass) -> TileLineStyle {
        let halfWidth = Float(pass.lineGeometry.lineWidth) * 0.5
        let edgeThreshold = halfWidth > 0
            ? halfWidth / ParseLine.extrudedHalfWidth(halfWidth: halfWidth)
            : 0
        return TileLineStyle(widthPoints: pass.lineWidthPoints,
                             dashLengthPoints: pass.dashLengthPoints,
                             dashGapPoints: pass.dashGapPoints,
                             edgeThreshold: edgeThreshold,
                             minimumWidthPoints: pass.minimumWidthPoints,
                             dashInTileUnits: pass.dashInTileUnits,
                             maximumWidthPoints: pass.maximumWidthPoints,
                             halfWidthUnits: halfWidth)
    }

    /// Expects the polygons already sorted by `OrderedRoadPolygon.sort`; the
    /// caller buckets and sorts once per structure/pass combination.
    private static func unifyOrderedRoadLayer(sortedRoadPolygons: [OrderedRoadPolygon],
                                              stylesByKey: [UInt8: BakedStyle]) -> (drawing: DrawingPolygonBytes,
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
                styles.append(TilePolygonStyle(color: style.color, farColor: style.farColor))
                overviewStyleMasks.append(style.lowZoomFadeMask)
                lineStyles.append(Self.makeTileLineStyle(from: style.pass))
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

    private static func makeDrawingGeometryLayer(
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

    private static func makeEmptyDrawingGeometryLayer() -> DrawingGeometryLayer {
        makeDrawingGeometryLayer(drawing: DrawingPolygonBytes(vertices: [], indices: []),
                                 styles: [],
                                 overviewStyleMasks: [],
                                 lineStyles: [])
    }

    static func unify(_ readingStageResult: ReadingStageResult) -> UnificationStageResult {
        let polygonByStyle = readingStageResult.polygonByStyle
        let roadPolygonByStyle = readingStageResult.roadPolygonByStyle
        let bridgePolygonByStyle = readingStageResult.bridgePolygonByStyle
        let extrudedByStyle = readingStageResult.extrudedByStyle

        let groundLayer = unifyPolygonLayer(polygonByStyle: polygonByStyle,
                                            stylesByKey: readingStageResult.styles,
                                            splitLinesClass: true)
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
                    // One mesh is one building: its footprint radius is
                    // the same on every vertex, for the screen-footprint
                    // level of detail (BuildingLODUniform).
                    let footprintRadius = Self.footprintRadius(of: extrudedMesh)
                    for vertex in extrudedMesh.vertices {
                        unifiedExtrudedVertices.append(ExtrudedVertexIn(position: vertex.position,
                                                                        normal: vertex.normal,
                                                                        styleIndex: styleBufferIndex,
                                                                        footprintRadius: footprintRadius))
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
            lineStyles: groundLayer.lineStyles,
            bridgeStyles: bridgeLayer.styles,
            bridgeOverviewStyleMasks: bridgeLayer.overviewStyleMasks,
            bridgeLineStyles: bridgeLayer.lineStyles
        )
    }
}
