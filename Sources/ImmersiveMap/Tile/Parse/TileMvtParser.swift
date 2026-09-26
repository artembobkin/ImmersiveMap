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
/// `Roads/` (with the per-layer pre-pass its line reader draws from) and
/// `Labels/`, all appending into one `ReadingStageResult`. The
/// folder knows no tile schema: it never reads an attribute by name and
/// never compares a layer name, since what a feature is (a building of
/// some height, a road in a tunnel) is the schema
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
    private let tileExtent = Float(TileCoordinateSpace.tileExtentDouble)

    init(mapStyle: MapStyleRuntime,
         labelDecisions: TileLabelDecisions,
         options: TileParseOptions) {
        self.mapStyle = mapStyle
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
        let decodedTile = try MvtTileDecoder.decode(data: mvtData)
        let readingStageResult = readingStage(decodedTile: decodedTile, tile: tile)
        let unificationResult = TileUnificationStage.unify(readingStageResult)

        return ParsedTile(
            drawingPolygon: unificationResult.drawingPolygon,
            drawingRoadPhases: unificationResult.drawingRoadPhases,
            drawingBridgePolygon: unificationResult.drawingBridgePolygon,
            drawingExtruded: unificationResult.drawingExtruded,
            styles: unificationResult.styles,
            styleZoomFades: unificationResult.styleZoomFades,
            lineStyles: unificationResult.lineStyles,
            bridgeStyles: unificationResult.bridgeStyles,
            bridgeStyleZoomFades: unificationResult.bridgeStyleZoomFades,
            bridgeLineStyles: unificationResult.bridgeLineStyles,
            tile: tile,
            textLabels: readingStageResult.textLabels,
            roadTextLabels: readingStageResult.roadTextLabels,
            parseLayerTimings: readingStageResult.layerTimings
        )
    }

    /// A layer with its features' attributes and facts read, before any
    /// feature is styled. The road layers of a tile are merged into one of
    /// these before reading.
    private struct PreparedLayer {
        var layer: MvtDecodedLayer
        var attributes: [[String: MvtValue]]
        var facts: [ImmersiveMapFeatureFacts]
        /// Any feature the reading found to be a road: the layer takes the
        /// road path, and merges with the tile's other road layers.
        var hasRoads: Bool
        var preparationNanoseconds: UInt64
    }

    /// Attributes and facts for every feature of every layer, then the
    /// road layers merged into the first of them, so the roads of a tile
    /// are one feature list for stitching and junction counting. Which
    /// layers those are is the reading's answer, feature by feature; a
    /// road layer whose extent differs from the first's stays on its own,
    /// since its coordinates would not line up.
    private func prepareLayers(decodedTile: MvtDecodedTile, tile: Tile) -> [PreparedLayer] {
        let mvtData = decodedTile.sourceData
        var prepared: [PreparedLayer] = []
        prepared.reserveCapacity(decodedTile.layers.count)
        mvtData.withUnsafeBytes { bytes in
            for layer in decodedTile.layers {
                let start = DispatchTime.now().uptimeNanoseconds
                var attributes: [[String: MvtValue]] = []
                attributes.reserveCapacity(layer.features.count)
                var facts: [ImmersiveMapFeatureFacts] = []
                facts.reserveCapacity(layer.features.count)
                var hasRoads = false
                for feature in layer.features {
                    let featureAttributes = MvtAttributeDecoder.attributes(of: feature, in: layer, bytes: bytes)
                    let featureFacts = mapStyle.readFacts(layerName: layer.name,
                                                          properties: featureAttributes,
                                                          tile: tile,
                                                          geometryType: feature.type)
                    hasRoads = hasRoads || featureFacts.road != nil
                    attributes.append(featureAttributes)
                    facts.append(featureFacts)
                }
                prepared.append(PreparedLayer(layer: layer,
                                              attributes: attributes,
                                              facts: facts,
                                              hasRoads: hasRoads,
                                              preparationNanoseconds: DispatchTime.now().uptimeNanoseconds - start))
            }
        }

        var merged: [PreparedLayer] = []
        merged.reserveCapacity(prepared.count)
        var roadLayerPosition: Int?
        for layer in prepared {
            if layer.hasRoads, let position = roadLayerPosition,
               merged[position].layer.extent == layer.layer.extent {
                MvtDecodedTile.append(layer.layer, to: &merged[position].layer, data: mvtData)
                merged[position].attributes.append(contentsOf: layer.attributes)
                merged[position].facts.append(contentsOf: layer.facts)
                merged[position].preparationNanoseconds += layer.preparationNanoseconds
                continue
            }
            if layer.hasRoads, roadLayerPosition == nil {
                roadLayerPosition = merged.count
            }
            merged.append(layer)
        }
        return merged
    }

    /// One pass over the layers. Per layer: attributes, facts and style for
    /// every feature, the building and road pre-passes over those, then
    /// every feature to its reader. After the layers: the synthesized
    /// labels, the ground's background and subdivision, the building
    /// meshes.
    func readingStage(decodedTile: MvtDecodedTile, tile: Tile) -> ReadingStageResult {
        let mvtData = decodedTile.sourceData
        let tools = TileParseTools()
        var result = ReadingStageResult()
        var buildingExtrusionCandidates: [BuildingExtrusionCandidate] = []
        var replacedBuildings = ReplacedBuildingFilter(replacedIDs: options.replacedBuildingIDs,
                                                       tileZoom: tile.z)

        for preparedLayer in prepareLayers(decodedTile: decodedTile, tile: tile) {
            let layerStart = DispatchTime.now().uptimeNanoseconds
            let layer = preparedLayer.layer
            let layerName = layer.name
            let layerGeometry = TileLayerGeometry(layer: layer, data: mvtData)

            // Styles resolve exactly once per feature here; the building and
            // road pre-passes below share them instead of asking again.
            let featureAttributes = preparedLayer.attributes
            let featureFacts = preparedLayer.facts
            var featureStyles: [FeatureStyle] = []
            featureStyles.reserveCapacity(layer.features.count)
            for (featureIndex, feature) in layer.features.enumerated() {
                featureStyles.append(mapStyle.makeStyle(data: DetFeatureStyleData(
                    layerName: layerName,
                    properties: featureAttributes[featureIndex],
                    tile: tile,
                    facts: featureFacts[featureIndex],
                    geometryType: feature.type
                )))
            }

            let buildingPartInfo = buildingReader.partInfo(geometry: layerGeometry, featureFacts: featureFacts)
            // The road path (stitching, structure and class order, the
            // decorations, drawn over the whole ground) is taken where the
            // style answered a road; a layer of plain lines stays on the
            // ground path.
            let usesSeparateRoadRendering = featureStyles.contains { style in
                if case .road = style { return true }
                return false
            }
            let roads = RoadLayerContext(
                usesSeparateRoadRendering: usesSeparateRoadRendering,
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
                if feature.type == .polygon, facts.building != nil, replacedBuildings.replaces(feature.id) {
                    replacedBuildings.record(outline: layerGeometry.polygons(of: feature))
                }
                if case .hidden = style {
                    // The style declines the feature: nothing to draw.
                    continue
                }

                if feature.type == .polygon {
                    readPolygons(of: feature,
                                 facts: facts,
                                 style: style,
                                 geometry: layerGeometry,
                                 buildingPartInfo: buildingPartInfo,
                                 roads: roads,
                                 tile: tile,
                                 tools: tools,
                                 extrusionCandidates: &buildingExtrusionCandidates,
                                 into: &result)
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
                    guard options.labelsEnabled, case .pointLabel(let label) = style else { continue }
                    labelReader.read(feature: feature,
                                     facts: facts,
                                     style: label,
                                     geometry: layerGeometry,
                                     layerName: layerName,
                                     tile: tile,
                                     into: &result)
                }
            }
            let elapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - layerStart
                + preparedLayer.preparationNanoseconds
            result.layerTimings.append(TileParseLayerTiming(layerName: layerName,
                                                            duration: TimeInterval(elapsedNanoseconds) / 1_000_000_000.0))

        }

        if options.labelsEnabled {
            labelReader.appendLowZoomWaterLabels(tile: tile, into: &result)
        }

        groundReader.finish(tile: tile, addTestBorders: options.addTestBorders, into: &result)

        // Only once every layer is read: an outline can come after its parts.
        buildingReader.appendExtrudedMeshes(resolving: replacedBuildings.remaining(buildingExtrusionCandidates),
                                            into: &result)

        result.removeEmptyBuckets()
        return result
    }

    /// A polygon feature by the case of its style: a fill (with the ocean
    /// split), a building (the footprint as a fill, plus the extrusion), a
    /// road (a carriageway surface into the road phases on the separate
    /// path, otherwise its fill stroke as a ground fill), a line whose
    /// style fills areas. A label or a line that draws only lines leaves
    /// the polygon undrawn.
    private func readPolygons(of feature: MvtDecodedFeature,
                              facts: ImmersiveMapFeatureFacts,
                              style: FeatureStyle,
                              geometry: TileLayerGeometry,
                              buildingPartInfo: BuildingFeatureReader.PartInfo,
                              roads: RoadLayerContext,
                              tile: Tile,
                              tools: TileParseTools,
                              extrusionCandidates: inout [BuildingExtrusionCandidate],
                              into result: inout ReadingStageResult) {
        let polygons = geometry.polygons(of: feature)
        switch style {
        case .fill(let fill):
            result.registerStyle(BakedStyle(fill: fill), key: fill.key, placement: .ground)
            let splitsComplexOceanHoles = groundReader.splitsComplexOceanHoles(fill: fill, polygons: polygons)
            for polygon in polygons {
                if splitsComplexOceanHoles,
                   groundReader.appendComplexOceanPolygon(polygon,
                                                          fill: fill,
                                                          into: &result,
                                                          parsePolygon: tools.parsePolygon,
                                                          tile: tile) {
                    continue
                }
                guard let parsedGeometry = tools.parsePolygon.parseGeometry(polygon: polygon,
                                                                            tileExtent: tileExtent) else {
                    continue
                }
                var parsedPolygon = parsedGeometry.parsedPolygon
                if fill.drawsAmongGroundLines {
                    parsedPolygon.makeLineClassFill()
                }
                result.appendGround(parsedPolygon, key: fill.key, placement: .ground)
            }
        case .extrusion(let extrusion):
            result.registerStyle(BakedStyle(extrusion: extrusion), key: extrusion.key, placement: .ground)
            let extrusionInfo = buildingReader.extrusion(feature: feature,
                                                         facts: facts,
                                                         style: extrusion,
                                                         polygons: polygons,
                                                         partInfo: buildingPartInfo,
                                                         tile: tile)
            for polygon in polygons {
                guard let parsedGeometry = tools.parsePolygon.parseGeometry(polygon: polygon,
                                                                            tileExtent: tileExtent) else {
                    continue
                }
                result.appendGround(parsedGeometry.parsedPolygon, key: extrusion.key, placement: .ground)
                if let extrusionInfo,
                   let candidate = buildingReader.candidate(polygon: polygon,
                                                            parsedGeometry: parsedGeometry,
                                                            styleKey: extrusion.key,
                                                            extrusion: extrusionInfo) {
                    extrusionCandidates.append(candidate)
                }
            }
        case .road(let roadStyle):
            if let fill = roadStyle.fill {
                appendGroundPolygons(polygons, pass: fill, placement: roadStyle.placement, tools: tools, into: &result)
            }
        case .line(let line):
            // A line style (boundary) that arrived as area geometry is not
            // filled unless the style says so: otherwise, for example, the
            // reservations in the `boundary` layer are drawn as solid
            // polygons.
            guard line.fillsAreas else { return }
            appendGroundPolygons(polygons, pass: line.pass, placement: line.placement, tools: tools, into: &result)
        case .pointLabel, .hidden:
            return
        }
    }

    /// Polygons filled with a stroke's colour: a line style on areal
    /// geometry, a road at a zoom where its surface is a plain fill.
    private func appendGroundPolygons(_ polygons: MultiPolygon,
                                      pass: LinePass,
                                      placement: LinePlacement,
                                      tools: TileParseTools,
                                      into result: inout ReadingStageResult) {
        result.registerStyle(BakedStyle(pass: pass), key: pass.key, placement: placement)
        for polygon in polygons {
            guard let parsedGeometry = tools.parsePolygon.parseGeometry(polygon: polygon,
                                                                        tileExtent: tileExtent) else {
                continue
            }
            result.appendGround(parsedGeometry.parsedPolygon, key: pass.key, placement: placement)
        }
    }
}
