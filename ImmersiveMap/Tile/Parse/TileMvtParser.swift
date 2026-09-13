// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd
import Mvt


class TileMvtParser {
    let determineFeatureStyle               : DetermineFeatureStyle
    let options                             : TileParseOptions
    private let labelDecisions              : TileLabelDecisions
    private let labelReader                 : LabelFeatureReader
    private let buildingReader              : BuildingFeatureReader
    private let groundReader                : GroundFeatureReader
    private let lineReader                  : LineFeatureReader
    private let roadSurfaceReader           : RoadSurfaceAreaReader = RoadSurfaceAreaReader()
    let tileExtent = TileCoordinateSpace.tileExtentDouble

    /// The MVT layer that carries roads: `road` in the Mapbox schema, `transportation`
    /// in OpenMapTiles, and `streetscape`, the tile service's measured
    /// carriageways and road paint, which arrive from a second archive and
    /// are folded into the road layer before this is asked (see
    /// `MvtRoadLayerFold`); the name is here for a tile that carries the
    /// streetscape and no road layer. Only this layer flows through the
    /// seamless, casing-under-fill separate-road rendering path.
    private static func isSeparateRoadLayer(_ layerName: String) -> Bool {
        layerName == "road" || layerName == "transportation" || layerName == MvtRoadLayerFold.streetscapeLayerName
    }

    /// With the streetscape off, the parser bakes no road paint: see
    /// `FeatureStyle.strippingRoadPaint()`. Decided here rather than in the
    /// style so that every style, the built-in one and a custom one alike,
    /// draws the same bare street map by default.
    private var stripsRoadPaint: Bool {
        options.streetscapeEnabled == false
    }

    
    init(determineFeatureStyle: DetermineFeatureStyle,
         labelDecisions: TileLabelDecisions,
         options: TileParseOptions) {
        self.determineFeatureStyle = determineFeatureStyle
        self.labelDecisions = labelDecisions
        self.labelReader = LabelFeatureReader(labelDecisions: labelDecisions,
                                              determineFeatureStyle: determineFeatureStyle)
        self.buildingReader = BuildingFeatureReader(options: options)
        self.groundReader = GroundFeatureReader(determineFeatureStyle: determineFeatureStyle)
        self.lineReader = LineFeatureReader(labelDecisions: labelDecisions, options: options)
        self.options = options
    }
    
    func parse(
        tile: Tile,
        mvtData: Data
    ) throws -> ParsedTile {
        let decodedTile = MvtRoadLayerFold.foldingStreetscapeLayers(try MvtTileDecoder.decode(data: mvtData))
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

    func readingStage(decodedTile: MvtDecodedTile, tile: Tile) -> ReadingStageResult {
        let mvtData = decodedTile.sourceData
        let tools = TileParseTools()
        var result = ReadingStageResult()
        var buildingExtrusionCandidates: [BuildingExtrusionCandidate] = []
        
        for layer in decodedTile.layers {
            let layerStart = DispatchTime.now().uptimeNanoseconds
            let layerName = layer.name
            let layerGeometry = TileLayerGeometry(layer: layer, data: mvtData)
            let usesSeparateRoadRendering = Self.isSeparateRoadLayer(layerName)
                && tile.z >= options.flatSeparateRoadRenderingMinimumZoom

            // Attributes and style resolve exactly once per feature here; the
            // building and road pre-passes below share them instead of
            // re-decoding the tag table per pass.
            var featureAttributes: [[String: MvtValue]] = []
            featureAttributes.reserveCapacity(layer.features.count)
            var featureStyles: [FeatureStyle] = []
            featureStyles.reserveCapacity(layer.features.count)
            mvtData.withUnsafeBytes { bytes in
                for feature in layer.features {
                    featureAttributes.append(MvtAttributeDecoder.attributes(of: feature, in: layer, bytes: bytes))
                }
                // A tunnel's road surface ships with the tunnel's `layer` but
                // without its `brunnel`; the surface is stamped as the tunnel
                // it roofs before the style reads it, so it draws the tunnel
                // look instead of open asphalt (see the resolver).
                if Self.isSeparateRoadLayer(layerName) {
                    for index in RoadTunnelSurfaceResolver.tunnelSurfaceIndices(layer: layer,
                                                                                  attributes: featureAttributes,
                                                                                  bytes: bytes) {
                        featureAttributes[index]["brunnel"] = .string("tunnel")
                    }
                }
                for attributes in featureAttributes {
                    featureStyles.append(determineFeatureStyle.makeStyle(data: DetFeatureStyleData(
                        layerName: layerName,
                        properties: attributes,
                        tile: tile,
                        streetscapeEnabled: options.streetscapeEnabled
                    )))
                }
                if stripsRoadPaint, Self.isSeparateRoadLayer(layerName) {
                    featureStyles = featureStyles.map { $0.strippingRoadPaint() }
                }
            }

            let buildingPartInfo = buildingReader.partInfo(layerName: layerName,
                                                           geometry: layerGeometry,
                                                           attributes: featureAttributes)
            let roads = RoadLayerContext(
                usesSeparateRoadRendering: usesSeparateRoadRendering,
                hasShippedCrossings: featureStyles.contains {
                    $0.isShippedRoadPaint && $0.roadDecorationKind == .zebraCrossing
                },
                precomputation: usesSeparateRoadRendering
                    ? RoadLayerPrecomputation.build(geometry: layerGeometry,
                                                    featureStyles: featureStyles,
                                                    featureAttributes: featureAttributes,
                                                    lineClipper: tools.lineClipper,
                                                    tile: tile)
                    : .empty
            )
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
                    result.registerStyle(style, key: styleKey, placement: style.linePlacement)
                }
                
                
                if feature.type == .polygon {
                    let polygons = layerGeometry.polygons(of: feature)
                    let shouldSplitComplexOceanHoles = groundReader.splitsComplexOceanHoles(layerName: layerName,
                                                                                            polygons: polygons)
                    let extrusion = buildingReader.extrusion(feature: feature,
                                                             attributes: attributes,
                                                             style: style,
                                                             polygons: polygons,
                                                             partInfo: buildingPartInfo,
                                                             tile: tile)
                    
                    for polygon in polygons {
                        if shouldSplitComplexOceanHoles,
                           groundReader.appendComplexOceanPolygon(polygon,
                                                                  style: style,
                                                                  into: &result,
                                                                  parsePolygon: tools.parsePolygon,
                                                                  tile: tile) {
                            continue
                        }

                        guard let parsedGeometry = tools.parsePolygon.parseGeometry(polygon: polygon,
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
                            roadSurfaceReader.append(parsedGeometry: parsedGeometry,
                                                     style: style,
                                                     attributes: attributes,
                                                     tile: tile,
                                                     surfaceAreas: roads.precomputation.surfaceAreas,
                                                     tools: tools,
                                                     into: &result)
                            continue
                        }
                        result.appendGround(parsedGeometry.parsedPolygon, key: styleKey, placement: style.linePlacement)
                        
                        if let extrusion,
                           let candidate = buildingReader.candidate(polygon: polygon,
                                                                    parsedGeometry: parsedGeometry,
                                                                    styleKey: styleKey,
                                                                    extrusion: extrusion) {
                            buildingExtrusionCandidates.append(candidate)
                        }
                    }
                    
                } else if feature.type == .linestring {
                    lineReader.read(feature: feature,
                                    featureIndex: featureIndex,
                                    attributes: attributes,
                                    style: style,
                                    geometry: layerGeometry,
                                    layerName: layerName,
                                    tile: tile,
                                    roads: roads,
                                    tools: tools,
                                    into: &result)
                } else if feature.type == .point {
                    // Point features exist only to be labelled: with labels
                    // off the layer is skipped whole, decision engine included.
                    guard options.labelsEnabled else { continue }
                    labelReader.read(feature: feature,
                                     attributes: attributes,
                                     style: style,
                                     geometry: layerGeometry,
                                     layerName: layerName,
                                     tile: tile,
                                     into: &result)
                }
            }
            roadSurfaceReader.appendSurfaceBridges(roads: roads.precomputation,
                                                   featureStyles: featureStyles,
                                                   featureAttributes: featureAttributes,
                                                   tile: tile,
                                                   tools: tools,
                                                   into: &result)
            let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - layerStart
            result.layerTimings.append(TileParseLayerTiming(layerName: layerName,
                                                     duration: TimeInterval(elapsedNanoseconds) / 1_000_000_000.0))

        }

        if options.labelsEnabled {
            labelReader.appendLowZoomWaterLabels(tile: tile, into: &result)
        }
        
        groundReader.finish(tile: tile, addTestBorders: options.addTestBorders, into: &result)

        buildingReader.appendExtrudedMeshes(resolving: buildingExtrusionCandidates, into: &result)
        
        result.removeEmptyBuckets()
        return result
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

    /// A line ribbon carries per-vertex line attributes (extruded stroke
    /// geometry); a fill does not, including the decoration polygons that
    /// share a line style (they default to the saturated line interior).
    /// Shared with `GroundGeometrySubdivider`, whose ribbon grid is coarser.
    static func isLineRibbon(_ polygon: ParsedPolygon) -> Bool {
        polygon.lineDistances.count == polygon.vertices.count
            && polygon.lineParameters.count == polygon.vertices.count
    }

    /// - Parameter splitLinesClass: orders the unified indices as three class
    ///   segments, fills first, then line ribbons, then the fills' outlines
    ///   (each by ascending style), and records the boundaries in
    ///   `DrawingPolygonBytes.fillsIndexCount` and `fillOutlinesIndexStart`.
    ///   The sphere's ground passes then draw one class without touching the
    ///   other's vertices; the paint order becomes "every ribbon above every
    ///   fill", which is also how the split flat/morph draws paint. The
    ///   outline segment is a line list the flat drawer alone reads.
    private func unifyPolygonLayer(polygonByStyle: [UInt8: [ParsedPolygon]],
                                   stylesByKey: [UInt8: FeatureStyle],
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
            splitLinesClass && stylesByKey[styleKey]?.fillOutlineAntialiasing == true
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
                    ? [{ Self.isLineRibbon($0) == false }, { Self.isLineRibbon($0) }]
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
                styles.append(TilePolygonStyle(color: style.color,
                                               streetColor: style.streetColor,
                                               farColor: style.farColor,
                                               farStreetColor: style.farStreetColor))
                overviewStyleMasks.append(style.lowZoomFadeMask)
                lineStyles.append(Self.makeTileLineStyle(from: style))
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
                styles.append(TilePolygonStyle(color: style.color,
                                               streetColor: style.streetColor,
                                               farColor: style.farColor,
                                               farStreetColor: style.farStreetColor))
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
                extrudedStyles.append(TilePolygonStyle(color: style.color, streetColor: style.streetColor))
            }
        }

        for styleKey in styleKeys {
            let styleBufferIndex = styleIndexByKey[styleKey] ?? 0
            if let extrudedMeshes = extrudedByStyle[styleKey] {
                for extrudedMesh in extrudedMeshes {
                    for vertex in extrudedMesh.vertices {
                        unifiedExtrudedVertices.append(ExtrudedVertexIn(position: vertex.position,
                                                                        normal: vertex.normal,
                                                                        styleIndex: styleBufferIndex))
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
