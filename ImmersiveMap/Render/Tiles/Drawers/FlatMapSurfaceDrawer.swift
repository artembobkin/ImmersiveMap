// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Metal
import simd

enum FlatMapSurfaceDrawer {
    private struct TileOverviewFadeUniform {
        var overviewAlpha: Float
        var roadAlpha: Float
        var landuseAlpha: Float
    }

    static func draw(renderEncoder: MTLRenderCommandEncoder,
                     cameraUniform: CameraUniform,
                     cameraZoom: Double,
                     separateRoadRenderingMinimumZoom: Int,
                     placeTilesContext: PlaceTilesContext,
                     flatRenderState: FlatRenderState,
                     tilePipeline: TilePipeline,
                     isWireframeEnabled: Bool) {
        tilePipeline.selectPipeline(renderEncoder: renderEncoder)
        if isWireframeEnabled {
            renderEncoder.setTriangleFillMode(.lines)
        }
        var cameraUniformValue = cameraUniform
        var overviewFadeUniform = TileOverviewFadeUniform(
            overviewAlpha: LowZoomOverviewFade.alpha(for: cameraZoom, kind: .overviewFeatures),
            roadAlpha: LowZoomOverviewFade.alpha(for: cameraZoom, kind: .roads),
            landuseAlpha: LowZoomOverviewFade.alpha(for: cameraZoom, kind: .landuse)
        )
        renderEncoder.setVertexBytes(&cameraUniformValue, length: MemoryLayout<CameraUniform>.stride, index: 1)
        renderEncoder.setFragmentBytes(&overviewFadeUniform,
                                       length: MemoryLayout<TileOverviewFadeUniform>.stride,
                                       index: 0)

        let usesSeparateRoadRendering = cameraZoom >= Double(separateRoadRenderingMinimumZoom)

        func drawLayer(_ keyPath: KeyPath<TileBuffers, TileBuffers.GeometryLayer>) {
            for placeTile in placeTilesContext.tilePlacements {
                let metalTile = placeTile.metalTile
                drawFlatGeometryLayer(renderEncoder: renderEncoder,
                                      buffers: metalTile.tileBuffers[keyPath: keyPath],
                                      tile: metalTile.tile,
                                      placeIn: placeTile.placeIn,
                                      flatRenderState: flatRenderState)
            }
        }

        drawLayer(\.ground)

        if usesSeparateRoadRendering {
            func drawRoadGroup(_ structureKind: TileMvtParser.RoadStructureKind) {
                for role in [RoadPassRole.shadow, .casing, .fill, .detail] {
                    for placeTile in placeTilesContext.tilePlacements {
                        let metalTile = placeTile.metalTile
                        let structureBucket = metalTile.tileBuffers.roads.bucket(for: structureKind)
                        drawFlatGeometryLayer(renderEncoder: renderEncoder,
                                              buffers: structureBucket.layer(for: role),
                                              tile: metalTile.tile,
                                              placeIn: placeTile.placeIn,
                                              flatRenderState: flatRenderState)
                    }
                }
            }

            drawRoadGroup(.tunnel)
            drawRoadGroup(.ground)
            drawLayer(\.bridgeOverlay)
            drawRoadGroup(.bridge)

            for structureKind in [TileMvtParser.RoadStructureKind.tunnel, .ground, .bridge] {
                for placeTile in placeTilesContext.tilePlacements {
                    let metalTile = placeTile.metalTile
                    let structureBucket = metalTile.tileBuffers.roads.bucket(for: structureKind)
                    drawFlatGeometryLayer(renderEncoder: renderEncoder,
                                          buffers: structureBucket.layer(for: .overlay),
                                          tile: metalTile.tile,
                                          placeIn: placeTile.placeIn,
                                          flatRenderState: flatRenderState)
                }
            }
        } else {
            drawLayer(\.bridgeOverlay)
        }
        if isWireframeEnabled {
            renderEncoder.setTriangleFillMode(.fill)
        }
    }

    private static func drawFlatGeometryLayer(renderEncoder: MTLRenderCommandEncoder,
                                              buffers: TileBuffers.GeometryLayer,
                                              tile: Tile,
                                              placeIn: VisibleTile,
                                              flatRenderState: FlatRenderState) {
        guard buffers.indicesCount > 0 else { return }

        let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.x,
                                                                         y: tile.y,
                                                                         z: tile.z,
                                                                         loop: placeIn.loop,
                                                                         flatRenderPan: flatRenderState.pan,
                                                                         renderMapSize: flatRenderState.renderMapSize)
        let scale = originAndSize.z / 4096.0

        renderEncoder.setVertexBuffer(buffers.verticesBuffer, offset: 0, index: 0)
        renderEncoder.setVertexBuffer(buffers.stylesBuffer, offset: 0, index: 2)
        renderEncoder.setVertexBuffer(buffers.overviewStyleMaskBuffer, offset: 0, index: 4)

        // Retained-подмена рисует source-тайл целиком по его origin: фрагменты
        // вне слота placeIn отбрасываются в шейдере, иначе контент родителя
        // перекрывал бы соседние точные тайлы во всех слоях (дороги, фоны).
        var localClipBounds = TileLocalClipMath.clipBounds(source: tile, placeIn: placeIn.tile)
        renderEncoder.setFragmentBytes(&localClipBounds,
                                       length: MemoryLayout<SIMD4<Float>>.stride,
                                       index: 1)

        var modelMatrix = Matrix.translationMatrix(
            x: originAndSize.x,
            y: originAndSize.y,
            z: 0
        ) * Matrix.scaleMatrix(sx: scale, sy: scale, sz: 1)
        renderEncoder.setVertexBytes(&modelMatrix, length: MemoryLayout<matrix_float4x4>.stride, index: 3)

        renderEncoder.drawIndexedPrimitives(type: .triangle,
                                            indexCount: buffers.indicesCount,
                                            indexType: .uint32,
                                            indexBuffer: buffers.indicesBuffer,
                                            indexBufferOffset: 0)
    }
}
