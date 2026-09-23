// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// What one tile parses to: every geometry layer unified into GPU-ready
/// streams, the styles they index, and the labels the layers carried,
/// as `TilePreparedDataBuilder` turns into a `PreparedTileCPU`. A class so
/// the loader passes one reference around instead of copying the streams.
final class ParsedTile {
    let drawingPolygon: DrawingPolygonBytes
    let drawingRoadPhases: RoadStructureBuckets<RoadGeometryPhases<DrawingGeometryLayer>>
    let drawingBridgePolygon: DrawingPolygonBytes
    let drawingExtruded: DrawingExtrudedBytes
    let styles: [TilePolygonStyle]
    let styleZoomFades: [SIMD2<Float>]
    let lineStyles: [TileLineStyle]
    let bridgeStyles: [TilePolygonStyle]
    let bridgeStyleZoomFades: [SIMD2<Float>]
    let bridgeLineStyles: [TileLineStyle]
    let tile: Tile
    let textLabels: [ParsedTextLabel]
    let roadTextLabels: [ParsedRoadTextLabel]
    let parseLayerTimings: [TileParseLayerTiming]

    init(
        drawingPolygon: DrawingPolygonBytes,
        drawingRoadPhases: RoadStructureBuckets<RoadGeometryPhases<DrawingGeometryLayer>>,
        drawingBridgePolygon: DrawingPolygonBytes,
        drawingExtruded: DrawingExtrudedBytes,
        styles: [TilePolygonStyle],
        styleZoomFades: [SIMD2<Float>],
        lineStyles: [TileLineStyle],
        bridgeStyles: [TilePolygonStyle],
        bridgeStyleZoomFades: [SIMD2<Float>],
        bridgeLineStyles: [TileLineStyle],
        tile: Tile,
        textLabels: [ParsedTextLabel],
        roadTextLabels: [ParsedRoadTextLabel],
        parseLayerTimings: [TileParseLayerTiming]
    ) {
        self.drawingPolygon = drawingPolygon
        self.drawingRoadPhases = drawingRoadPhases
        self.drawingBridgePolygon = drawingBridgePolygon
        self.drawingExtruded = drawingExtruded
        self.styles = styles
        self.styleZoomFades = styleZoomFades
        self.lineStyles = lineStyles
        self.bridgeStyles = bridgeStyles
        self.bridgeStyleZoomFades = bridgeStyleZoomFades
        self.bridgeLineStyles = bridgeLineStyles
        self.tile = tile
        self.textLabels = textLabels
        self.roadTextLabels = roadTextLabels
        self.parseLayerTimings = parseLayerTimings
    }
}
