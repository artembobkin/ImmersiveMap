// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

final class TilePreparedDataBuilder {
    private let tileParser: TileMvtParser
    private let textLabelsBuilder: TileTextLabelsBuilder
    private let roadLabelsBuilder: TileRoadLabelsBuilder
    private let surfaceLabelsBuilder: TileSurfaceLabelsBuilder

    init(tileParser: TileMvtParser,
         textLabelsBuilder: TileTextLabelsBuilder,
         roadLabelsBuilder: TileRoadLabelsBuilder,
         surfaceLabelsBuilder: TileSurfaceLabelsBuilder) {
        self.tileParser = tileParser
        self.textLabelsBuilder = textLabelsBuilder
        self.roadLabelsBuilder = roadLabelsBuilder
        self.surfaceLabelsBuilder = surfaceLabelsBuilder
    }

    func build(tile: Tile, data: Data) throws -> PreparedTileLoadResult {
        let parsedTile = try tileParser.parse(tile: tile, mvtData: data)
        // A label stands on the screen or lies on the map, never both.
        let screenLabels = parsedTile.textLabels.filter { $0.placement == .screen }
        let textLabels = textLabelsBuilder.build(textLabels: screenLabels, tile: tile)
        let surfaceLabels = surfaceLabelsBuilder.build(textLabels: parsedTile.textLabels, tile: tile)
        let roadLabels = roadLabelsBuilder.build(roadTextLabels: parsedTile.roadTextLabels, tile: tile)

        let preparedTile = PreparedTileCPU(
            tile: tile,
            ground: PreparedTileCPU.GeometryLayer(vertices: parsedTile.drawingPolygon.vertices,
                                                  indices: parsedTile.drawingPolygon.indices,
                                                  styles: parsedTile.styles,
                                                  styleZoomFades: parsedTile.styleZoomFades,
                                                  lineStyles: parsedTile.lineStyles,
                                                  fillsIndexCount: parsedTile.drawingPolygon.fillsIndexCount),
            roads: parsedTile.drawingRoadPhases.map { structureBucket in
                structureBucket.map { phase in
                    PreparedTileCPU.GeometryLayer(vertices: phase.drawing.vertices,
                                                 indices: phase.drawing.indices,
                                                 styles: phase.styles,
                                                 styleZoomFades: phase.styleZoomFades,
                                                 lineStyles: phase.lineStyles)
                }
            },
            bridgeOverlay: PreparedTileCPU.GeometryLayer(vertices: parsedTile.drawingBridgePolygon.vertices,
                                                         indices: parsedTile.drawingBridgePolygon.indices,
                                                         styles: parsedTile.bridgeStyles,
                                                         styleZoomFades: parsedTile.bridgeStyleZoomFades,
                                                         lineStyles: parsedTile.bridgeLineStyles),
            extruded: PreparedTileCPU.Extruded(vertices: parsedTile.drawingExtruded.vertices,
                                               indices: parsedTile.drawingExtruded.indices,
                                               styles: parsedTile.drawingExtruded.styles),
            textLabels: textLabels,
            roadLabels: roadLabels,
            surfaceLabels: surfaceLabels
        )
        return PreparedTileLoadResult(preparedTile: preparedTile,
                                      parseLayerTimings: parsedTile.parseLayerTimings)
    }
}
