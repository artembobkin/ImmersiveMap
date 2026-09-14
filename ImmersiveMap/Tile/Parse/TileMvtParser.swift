// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd
import Mvt

/// Turns the bytes of one vector tile into a `ParsedTile`. The parser is
/// the dispatcher: `readingStage` walks the layers, resolves every
/// feature's attributes and style exactly once, and hands each feature to
/// the reader for its geometry kind; `TileUnificationStage` packs the
/// result. One parser serves every parse of a map, from any thread: it
/// holds nothing per tile, and the readers hold nothing across tiles.
///
/// This is the `Parse` folder's boundary. What a parse depends on comes in
/// through the initializer and nothing else: `TileParseOptions` (the
/// settings a parse reads, picked out of the settings tree by the caller,
/// which is the folder's one look at `ImmersiveMapSettings`),
/// `TileLabelDecisions` (the label policy, assembled in
/// `VectorTileAdaptation`) and the style. What it produces is `Contract/`:
/// `ParsedTile` and the types it is made of, plus the types the styles and
/// the render side share with the parser, which they name directly and
/// never through the parser's internals. One reader per geometry kind,
/// each a struct with no state across tiles: `Ground/`, `Buildings/`,
/// `Roads/` (with the per-layer pre-pass its line and surface readers draw
/// from) and `Labels/`, all appending into one `ReadingStageResult`. The
/// folder knows no tile schema: it never reads an attribute by name and
/// never compares a layer name, since what a feature is (a building of
/// some height, a road in a tunnel, a piece of some street) is the schema
/// reading's answer (`ImmersiveMapFeatureFacts`), and how it draws is the
/// style's (`FeatureStyle`); the parser carries the two side by side for
/// every feature. It holds no label policy, no Metal, and no loading,
/// caching or networking. Every geometry follows the y-axis contract
/// stated once in `TileCoordinateSpace`.
final class TileMvtParser {
    private let mapStyle: MapStyleRuntime
    private let options: TileParseOptions
    private let labelReader: LabelFeatureReader
    private let buildingReader: BuildingFeatureReader
    private let groundReader: GroundFeatureReader
    private let lineReader: LineFeatureReader
    private let roadSurfaceReader = RoadSurfaceAreaReader()
    private let tileExtent = Float(TileCoordinateSpace.tileExtentDouble)
    /// The style's road layers, and its streetscape layer: the measured
    /// carriageways and road paint, which arrive from a second archive and
    /// are folded into the road layer before the layers are read. The name
    /// is here for a tile that carries the streetscape and no road layer.
    private let roadLayerNames: Set<String>
    private let streetscapeLayerName: String?

    /// Only a road layer flows through the seamless, casing-under-fill
    /// separate-road rendering path.
    private func isSeparateRoadLayer(_ layerName: String) -> Bool {
        roadLayerNames.contains(layerName) || layerName == streetscapeLayerName
    }

    /// With the streetscape off, the parser bakes no road paint: see
    /// `FeatureStyle.strippingRoadPaint()`. Decided here rather than in the
    /// style so that every style, the built-in one and a custom one alike,
    /// draws the same bare street map by default.
    private var stripsRoadPaint: Bool {
        options.streetscapeEnabled == false
    }

    init(mapStyle: MapStyleRuntime,
         labelDecisions: TileLabelDecisions,
         options: TileParseOptions) {
        self.mapStyle = mapStyle
        self.roadLayerNames = mapStyle.roadLayerNames
        self.streetscapeLayerName = mapStyle.streetscapeLayerName
        self.labelReader = LabelFeatureReader(labelDecisions: labelDecisions, mapStyle: mapStyle)
        self.buildingReader = BuildingFeatureReader(options: options)
        self.groundReader = GroundFeatureReader(mapStyle: mapStyle)
        self.lineReader = LineFeatureReader(labelDecisions: labelDecisions, options: options)
        self.options = options
    }

    func parse(
        tile: Tile,
        mvtData: Data
    ) throws -> ParsedTile {
        var decodedTile = try MvtTileDecoder.decode(data: mvtData)
        if let streetscapeLayerName {
            // The streetscape's surfaces and paint and the roads they
            // belong to have to be one feature list: the surfaces clip the
            // ribbons of the roads that enter them, a measured crossing
            // suppresses the crossing read off the same road's attributes,
            // the tunnel roofs are found among the surfaces. The decoder
            // does the merge; the style names the layers.
            decodedTile = decodedTile.merging(layersNamed: streetscapeLayerName, intoFirstLayerNamed: roadLayerNames)
        }
        let readingStageResult = readingStage(decodedTile: decodedTile, tile: tile)
        let unificationResult = TileUnificationStage.unify(readingStageResult)

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

    /// One pass over the layers. Per layer: attributes and style for every
    /// feature, the building and road pre-passes over those, then every
    /// feature to its reader. After the layers: the synthesized labels, the
    /// ground's background and subdivision, the building meshes.
    func readingStage(decodedTile: MvtDecodedTile, tile: Tile) -> ReadingStageResult {
        let mvtData = decodedTile.sourceData
        let tools = TileParseTools()
        var result = ReadingStageResult()
        var buildingExtrusionCandidates: [BuildingExtrusionCandidate] = []

        for layer in decodedTile.layers {
            let layerStart = DispatchTime.now().uptimeNanoseconds
            let layerName = layer.name
            let layerGeometry = TileLayerGeometry(layer: layer, data: mvtData)
            let usesSeparateRoadRendering = isSeparateRoadLayer(layerName)
                && tile.z >= options.flatSeparateRoadRenderingMinimumZoom

            // Attributes, facts and style resolve exactly once per feature
            // here; the building and road pre-passes below share them
            // instead of re-decoding the tag table per pass.
            var featureAttributes: [[String: MvtValue]] = []
            featureAttributes.reserveCapacity(layer.features.count)
            var featureFacts: [ImmersiveMapFeatureFacts] = []
            featureFacts.reserveCapacity(layer.features.count)
            var featureStyles: [FeatureStyle] = []
            featureStyles.reserveCapacity(layer.features.count)
            mvtData.withUnsafeBytes { bytes in
                for feature in layer.features {
                    featureAttributes.append(MvtAttributeDecoder.attributes(of: feature, in: layer, bytes: bytes))
                }
                for (featureIndex, feature) in layer.features.enumerated() {
                    featureFacts.append(mapStyle.readFacts(layerName: layerName,
                                                           properties: featureAttributes[featureIndex],
                                                           tile: tile,
                                                           geometryType: feature.type))
                }
                // A tunnel's road surface ships with the tunnel's `layer` but
                // says nothing of the tunnel itself: the one fact the engine
                // adds to the reading, so the style draws the surface as the
                // tunnel's roof instead of open asphalt.
                if isSeparateRoadLayer(layerName) {
                    for index in RoadTunnelSurfaceResolver.tunnelSurfaceIndices(layer: layer,
                                                                                  featureFacts: featureFacts,
                                                                                  bytes: bytes) {
                        featureFacts[index].road?.isTunnelRoof = true
                    }
                }
                for (featureIndex, feature) in layer.features.enumerated() {
                    var style = mapStyle.makeStyle(data: DetFeatureStyleData(
                        layerName: layerName,
                        properties: featureAttributes[featureIndex],
                        tile: tile,
                        facts: featureFacts[featureIndex],
                        streetscapeEnabled: options.streetscapeEnabled,
                        geometryType: feature.type
                    ))
                    if stripsRoadPaint, isSeparateRoadLayer(layerName) {
                        style = style.strippingRoadPaint(
                            isShippedPaint: featureFacts[featureIndex].road?.isShippedPaint == true)
                    }
                    featureStyles.append(style)
                }
            }

            let buildingPartInfo = buildingReader.partInfo(geometry: layerGeometry, featureFacts: featureFacts)
            let roads = RoadLayerContext(
                usesSeparateRoadRendering: usesSeparateRoadRendering,
                hasShippedCrossings: zip(featureFacts, featureStyles).contains {
                    $0.road?.isShippedPaint == true && $1.roadDecorationKind == .zebraCrossing
                },
                precomputation: usesSeparateRoadRendering
                    ? RoadLayerPrecomputation.build(geometry: layerGeometry,
                                                    featureFacts: featureFacts,
                                                    featureStyles: featureStyles,
                                                    lineClipper: tools.lineClipper,
                                                    tile: tile)
                    : .empty
            )
            for (featureIndex, feature) in layer.features.enumerated() {
                let attributes = featureAttributes[featureIndex]
                let facts = featureFacts[featureIndex]
                let style = featureStyles[featureIndex]
                let styleKey = style.key
                if styleKey == 0 {
                    // The style declines the feature: nothing to draw.
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
                    let shouldSplitComplexOceanHoles = groundReader.splitsComplexOceanHoles(style: style,
                                                                                            polygons: polygons)
                    let extrusion = buildingReader.extrusion(feature: feature,
                                                             facts: facts,
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
                                                                                    tileExtent: tileExtent) else {
                            continue
                        }
                        if let road = facts.road, road.isSurface, usesSeparateRoadRendering {
                            // A carriageway surface (junction area) joins the
                            // road phases instead of the ground: its fill pass
                            // is the triangulated polygon, its casing pass the
                            // outline tessellated as a closed kerb. Sorted among
                            // the roads by class, so the surface covers the
                            // kerbs of the ribbons that run into it.
                            roadSurfaceReader.append(parsedGeometry: parsedGeometry,
                                                     road: road,
                                                     style: style,
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
                                    facts: facts,
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
                                     facts: facts,
                                     style: style,
                                     geometry: layerGeometry,
                                     layerName: layerName,
                                     tile: tile,
                                     into: &result)
                }
            }
            roadSurfaceReader.appendSurfaceBridges(roads: roads.precomputation,
                                                   featureFacts: featureFacts,
                                                   featureStyles: featureStyles,
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
}
