// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

enum FlatMapSurfaceDrawer {
    private struct TileOverviewFadeUniform {
        var overviewAlpha: Float
        var roadAlpha: Float
        var landuseAlpha: Float
        /// Converts the per-style point-locked line widths into the pixels the
        /// shader's coverage math runs in.
        var pixelsPerPoint: Float
    }

    static func draw(renderEncoder: MTLRenderCommandEncoder,
                     cameraUniform: CameraUniform,
                     cameraZoom: Double,
                     pixelsPerPoint: Float,
                     drawableHeightPx: Float,
                     separateRoadRenderingMinimumZoom: Int,
                     placeTilesContext: PlaceTilesContext,
                     flatRenderState: FlatRenderState,
                     horizonFog: HorizonFogUniform,
                     shadowBinding: ShadowReceiverBinding,
                     tilePipeline: TilePipeline,
                     isWireframeEnabled: Bool,
                     withBuildingImageAttachment: Bool = false) {
        tilePipeline.selectPipeline(renderEncoder: renderEncoder,
                                    withBuildingImageAttachment: withBuildingImageAttachment)
        if isWireframeEnabled {
            renderEncoder.setTriangleFillMode(.lines)
        }
        var cameraUniformValue = cameraUniform
        // Continuous in camera zoom, so the ground palette never steps at a
        // tile-zoom boundary; the tiles bake both palettes per style.
        var streetPaletteUniform = StreetPaletteUniform(
            blend: LowZoomOverviewFade.streetPaletteBlend(for: cameraZoom)
        )
        renderEncoder.setVertexBytes(&streetPaletteUniform,
                                     length: MemoryLayout<StreetPaletteUniform>.stride,
                                     index: 6)
        // The taper thins point-locked widths toward planet zooms; continuous
        // in camera zoom, so it cannot reintroduce integer-zoom width jumps.
        var overviewFadeUniform = TileOverviewFadeUniform(
            overviewAlpha: LowZoomOverviewFade.alpha(for: cameraZoom, kind: .overviewFeatures),
            roadAlpha: LowZoomOverviewFade.alpha(for: cameraZoom, kind: .roads),
            landuseAlpha: LowZoomOverviewFade.alpha(for: cameraZoom, kind: .landuse),
            pixelsPerPoint: pixelsPerPoint * LineWidthZoomTaper.scale(for: cameraZoom)
        )
        var horizonFogValue = horizonFog
        var shadowUniformValue = shadowBinding.uniform
        renderEncoder.setVertexBytes(&cameraUniformValue, length: MemoryLayout<CameraUniform>.stride, index: 1)
        renderEncoder.setFragmentBytes(&overviewFadeUniform,
                                       length: MemoryLayout<TileOverviewFadeUniform>.stride,
                                       index: 0)
        renderEncoder.setFragmentBytes(&horizonFogValue,
                                       length: MemoryLayout<HorizonFogUniform>.stride,
                                       index: 2)
        renderEncoder.setFragmentBytes(&shadowUniformValue,
                                       length: MemoryLayout<ShadowUniform>.stride,
                                       index: 3)
        renderEncoder.setFragmentTexture(shadowBinding.texture, index: 0)

        let usesSeparateRoadRendering = cameraZoom >= Double(separateRoadRenderingMinimumZoom)

        func drawLayer(_ keyPath: KeyPath<TileBuffers, TileBuffers.GeometryLayer>) {
            for placeTile in placeTilesContext.tilePlacements {
                let metalTile = placeTile.metalTile
                drawFlatGeometryLayer(renderEncoder: renderEncoder,
                                      buffers: metalTile.tileBuffers[keyPath: keyPath],
                                      tile: metalTile.tile,
                                      placeIn: placeTile.placeIn,
                                      flatRenderState: flatRenderState,
                                      pixelsPerPoint: pixelsPerPoint,
                                      drawableHeightPx: drawableHeightPx)
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
                                              flatRenderState: flatRenderState,
                                              pixelsPerPoint: pixelsPerPoint,
                                              drawableHeightPx: drawableHeightPx)
                    }
                }
            }

            drawRoadGroup(.tunnel)
            drawRoadGroup(.ground)
            drawRoadGroup(.automobileGround)
            drawLayer(\.bridgeOverlay)
            drawRoadGroup(.bridge)

            for structureKind in TileMvtParser.RoadStructureKind.drawOrder {
                for placeTile in placeTilesContext.tilePlacements {
                    let metalTile = placeTile.metalTile
                    let structureBucket = metalTile.tileBuffers.roads.bucket(for: structureKind)
                    drawFlatGeometryLayer(renderEncoder: renderEncoder,
                                          buffers: structureBucket.layer(for: .overlay),
                                          tile: metalTile.tile,
                                          placeIn: placeTile.placeIn,
                                          flatRenderState: flatRenderState,
                                          pixelsPerPoint: pixelsPerPoint,
                                          drawableHeightPx: drawableHeightPx)
                }
            }
        } else {
            drawLayer(\.bridgeOverlay)
        }
        if isWireframeEnabled {
            renderEncoder.setTriangleFillMode(.fill)
        }
    }

    private struct LineDashUniform {
        var unitsPerPoint: Float
    }

    private struct StreetPaletteUniform {
        var blend: Float
    }

    private static func drawFlatGeometryLayer(renderEncoder: MTLRenderCommandEncoder,
                                              buffers: TileBuffers.GeometryLayer,
                                              tile: Tile,
                                              placeIn: VisibleTile,
                                              flatRenderState: FlatRenderState,
                                              pixelsPerPoint: Float,
                                              drawableHeightPx: Float) {
        guard buffers.indicesCount > 0,
              let indices = buffers.indices,
              let vertices = buffers.vertices,
              let styles = buffers.styles,
              let overviewStyleMask = buffers.overviewStyleMask,
              let lineStyles = buffers.lineStyles else { return }

        let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.x,
                                                                         y: tile.y,
                                                                         z: tile.z,
                                                                         loop: placeIn.loop,
                                                                         flatRenderPan: flatRenderState.pan,
                                                                         renderMapSize: flatRenderState.renderMapSize)
        let scale = originAndSize.z / 4096.0

        renderEncoder.setVertexBuffer(vertices.buffer, offset: vertices.offset, index: 0)
        renderEncoder.setVertexBuffer(styles.buffer, offset: styles.offset, index: 2)
        renderEncoder.setVertexBuffer(overviewStyleMask.buffer, offset: overviewStyleMask.offset, index: 4)
        renderEncoder.setVertexBuffer(lineStyles.buffer, offset: lineStyles.offset, index: 5)

        // A retained substitution draws the source tile in full at its origin:
        // fragments outside the placeIn slot are discarded in the shader,
        // otherwise the parent's content would cover neighboring exact tiles
        // in every layer (roads, backgrounds).
        var localClipBounds = TileLocalClipMath.clipBounds(source: tile, placeIn: placeIn.tile)
        renderEncoder.setFragmentBytes(&localClipBounds,
                                       length: MemoryLayout<SIMD4<Float>>.stride,
                                       index: 1)

        // Anchors point-dashed patterns to the geometry: the scale depends on
        // the source tile's world size and the viewport, never on the live
        // camera, so dashes hold still under camera motion (untapered on
        // purpose: a pattern must not stretch with the zoom taper either).
        var lineDashUniform = LineDashUniform(
            unitsPerPoint: pixelsPerPoint * LineDashNominalScale.unitsPerPixel(
                sourceTileWorldSize: originAndSize.z,
                drawableHeightPx: drawableHeightPx
            )
        )
        renderEncoder.setFragmentBytes(&lineDashUniform,
                                       length: MemoryLayout<LineDashUniform>.stride,
                                       index: 4)

        var modelMatrix = Matrix.translationMatrix(
            x: originAndSize.x,
            y: originAndSize.y,
            z: 0
        ) * Matrix.scaleMatrix(sx: scale, sy: scale, sz: 1)
        renderEncoder.setVertexBytes(&modelMatrix, length: MemoryLayout<matrix_float4x4>.stride, index: 3)

        renderEncoder.drawIndexedPrimitives(type: .triangle,
                                            indexCount: indices.count,
                                            indexType: buffers.indexType,
                                            indexBuffer: indices.buffer,
                                            indexBufferOffset: indices.offset)
    }
}
