// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

extension TileMvtParser {
    struct DrawingGeometryLayer {
        let drawing: DrawingPolygonBytes
        let styles: [TilePolygonStyle]
        let overviewStyleMasks: [Float]
        let lineStyles: [TileLineStyle]
    }

    class ParsedTile {
        let drawingPolygon: DrawingPolygonBytes
        let drawingRoadPhases: RoadStructureBuckets<RoadGeometryPhases<DrawingGeometryLayer>>
        let drawingBridgePolygon: DrawingPolygonBytes
        let drawingExtruded: DrawingExtrudedBytes
        let styles: [TilePolygonStyle]
        let overviewStyleMasks: [Float]
        let lineStyles: [TileLineStyle]
        let bridgeStyles: [TilePolygonStyle]
        let bridgeOverviewStyleMasks: [Float]
        let bridgeLineStyles: [TileLineStyle]
        let tile: Tile
        let textLabels: [TextLabel]
        let roadTextLabels: [RoadTextLabel]
        let parseLayerTimings: [TileParseLayerTiming]

        init(
            drawingPolygon: DrawingPolygonBytes,
            drawingRoadPhases: RoadStructureBuckets<RoadGeometryPhases<DrawingGeometryLayer>>,
            drawingBridgePolygon: DrawingPolygonBytes,
            drawingExtruded: DrawingExtrudedBytes,
            styles: [TilePolygonStyle],
            overviewStyleMasks: [Float],
            lineStyles: [TileLineStyle],
            bridgeStyles: [TilePolygonStyle],
            bridgeOverviewStyleMasks: [Float],
            bridgeLineStyles: [TileLineStyle],
            tile: Tile,
            textLabels: [TextLabel],
            roadTextLabels: [RoadTextLabel],
            parseLayerTimings: [TileParseLayerTiming]
        ) {
            self.drawingPolygon = drawingPolygon
            self.drawingRoadPhases = drawingRoadPhases
            self.drawingBridgePolygon = drawingBridgePolygon
            self.drawingExtruded = drawingExtruded
            self.styles = styles
            self.overviewStyleMasks = overviewStyleMasks
            self.lineStyles = lineStyles
            self.bridgeStyles = bridgeStyles
            self.bridgeOverviewStyleMasks = bridgeOverviewStyleMasks
            self.bridgeLineStyles = bridgeLineStyles
            self.tile = tile
            self.textLabels = textLabels
            self.roadTextLabels = roadTextLabels
            self.parseLayerTimings = parseLayerTimings
        }
    }
}
