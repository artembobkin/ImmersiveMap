// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

final class TilePreparedDataBuilder {
    private let tileParser: TileMvtParser
    private let textLabelsBuilder: TileTextLabelsBuilder
    private let roadLabelsBuilder: TileRoadLabelsBuilder

    init(tileParser: TileMvtParser,
         textLabelsBuilder: TileTextLabelsBuilder,
         roadLabelsBuilder: TileRoadLabelsBuilder) {
        self.tileParser = tileParser
        self.textLabelsBuilder = textLabelsBuilder
        self.roadLabelsBuilder = roadLabelsBuilder
    }

    func build(tile: Tile, data: Data) throws -> PreparedTileLoadResult {
        let parsedTile = try tileParser.parse(tile: tile, mvtData: data)
        let textLabels = textLabelsBuilder.build(textLabels: parsedTile.textLabels, tile: tile)
        let roadLabels = roadLabelsBuilder.build(roadTextLabels: parsedTile.roadTextLabels, tile: tile)

        let preparedTile = PreparedTileCPU(
            tile: tile,
            ground: PreparedTileCPU.GeometryLayer(vertices: parsedTile.drawingPolygon.vertices,
                                                  indices: parsedTile.drawingPolygon.indices,
                                                  styles: parsedTile.styles,
                                                  overviewStyleMasks: parsedTile.overviewStyleMasks,
                                                  lineWidthPoints: parsedTile.lineWidthPoints),
            roads: parsedTile.drawingRoadPhases.map { structureBucket in
                structureBucket.map { phase in
                    PreparedTileCPU.GeometryLayer(vertices: phase.drawing.vertices,
                                                 indices: phase.drawing.indices,
                                                 styles: phase.styles,
                                                 overviewStyleMasks: phase.overviewStyleMasks,
                                                 lineWidthPoints: phase.lineWidthPoints)
                }
            },
            bridgeOverlay: PreparedTileCPU.GeometryLayer(vertices: parsedTile.drawingBridgePolygon.vertices,
                                                         indices: parsedTile.drawingBridgePolygon.indices,
                                                         styles: parsedTile.bridgeStyles,
                                                         overviewStyleMasks: parsedTile.bridgeOverviewStyleMasks,
                                                         lineWidthPoints: parsedTile.bridgeLineWidthPoints),
            extruded: PreparedTileCPU.Extruded(vertices: parsedTile.drawingExtruded.vertices,
                                               indices: parsedTile.drawingExtruded.indices,
                                               styles: parsedTile.drawingExtruded.styles),
            textLabels: textLabels,
            roadLabels: roadLabels
        )
        return PreparedTileLoadResult(preparedTile: preparedTile,
                                      parseLayerTimings: parsedTile.parseLayerTimings)
    }
}
