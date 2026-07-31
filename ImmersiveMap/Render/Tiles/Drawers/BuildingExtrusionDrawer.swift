// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

enum BuildingExtrusionDrawer {
    private struct ExtrudedLightUniform {
        var direction: SIMD4<Float>
        var color: SIMD4<Float>
        var intensities: SIMD4<Float>
    }

    /// Opaque building geometry with depth test and depth write:
    /// solid mode draws it straight into the world pass, translucent into the
    /// offscreen building image.
    static func drawBuildings(renderEncoder: MTLRenderCommandEncoder,
                              cameraUniform: CameraUniform,
                              placeTilesContext: PlaceTilesContext,
                              flatRenderState: FlatRenderState,
                              extrudedTilePipeline: ExtrudedTilePipeline,
                              extrudedDepthState: MTLDepthStencilState,
                              depthDisabledState: MTLDepthStencilState) {
        var cameraUniformValue = cameraUniform
        renderEncoder.setCullMode(.back)

        extrudedTilePipeline.selectPipeline(renderEncoder: renderEncoder)
        renderEncoder.setDepthStencilState(extrudedDepthState)
        renderEncoder.setVertexBytes(&cameraUniformValue, length: MemoryLayout<CameraUniform>.stride, index: 1)
        renderEncoder.setFragmentBytes(&cameraUniformValue, length: MemoryLayout<CameraUniform>.stride, index: 1)

        let lightDirection = simd_normalize(SIMD3<Float>(-0.4, -0.6, 1.0))
        var lightUniform = ExtrudedLightUniform(
            direction: SIMD4<Float>(lightDirection, 0.0),
            color: SIMD4<Float>(1.0, 1.0, 1.0, 1.0),
            intensities: SIMD4<Float>(0.35, 0.65, 0.2, 24.0)
        )
        renderEncoder.setFragmentBytes(&lightUniform, length: MemoryLayout<ExtrudedLightUniform>.stride, index: 2)
        drawExtrudedGeometry(renderEncoder: renderEncoder,
                             placeTilesContext: placeTilesContext,
                             flatRenderState: flatRenderState)

        renderEncoder.setCullMode(.none)
        renderEncoder.setDepthStencilState(depthDisabledState)
    }

    /// Composites the building image over the world pass with a shared alpha:
    /// the premultiplied blend tints each map pixel exactly once, and the
    /// building silhouette coverage (smoothed by MSAA resolve) arrives in the
    /// image alpha.
    static func drawComposite(renderEncoder: MTLRenderCommandEncoder,
                              buildingImageTexture: MTLTexture,
                              alpha: Float,
                              extrudedTilePipeline: ExtrudedTilePipeline,
                              depthDisabledState: MTLDepthStencilState) {
        renderEncoder.setCullMode(.none)
        extrudedTilePipeline.selectCompositePipeline(renderEncoder: renderEncoder)
        renderEncoder.setDepthStencilState(depthDisabledState)
        renderEncoder.setFragmentTexture(buildingImageTexture, index: 0)
        var alphaValue = alpha
        renderEncoder.setFragmentBytes(&alphaValue, length: MemoryLayout<Float>.stride, index: 0)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    private static func drawExtrudedGeometry(renderEncoder: MTLRenderCommandEncoder,
                                             placeTilesContext: PlaceTilesContext,
                                             flatRenderState: FlatRenderState) {
        var isBackCullingEnabled = true
        for placeTile in placeTilesContext.tilePlacements {
            let metalTile = placeTile.metalTile
            let tile = metalTile.tile
            let buffers = metalTile.tileBuffers
            let placeIn = placeTile.placeIn

            guard buffers.extruded.indicesCount > 0,
                  let extrudedIndicesBuffer = buffers.extruded.indicesBuffer else { continue }

            let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.x,
                                                                             y: tile.y,
                                                                             z: tile.z,
                                                                             loop: placeIn.loop,
                                                                             flatRenderPan: flatRenderState.pan,
                                                                             renderMapSize: flatRenderState.renderMapSize)
            let scale = originAndSize.z / 4096.0

            renderEncoder.setVertexBuffer(buffers.extruded.verticesBuffer, offset: 0, index: 0)
            renderEncoder.setVertexBuffer(buffers.extruded.stylesBuffer, offset: 0, index: 2)

            // Clip fragments to the placeIn slot: buildings of a retained parent
            // must not overlap neighboring exact tiles.
            var localClipBounds = TileLocalClipMath.clipBounds(source: tile, placeIn: placeIn.tile)
            renderEncoder.setFragmentBytes(&localClipBounds,
                                           length: MemoryLayout<SIMD4<Float>>.stride,
                                           index: 4)

            // The clip cuts a building with a vertical plane and no capping face:
            // with back-face culling the cut looks hollow all the way through.
            // For clipped placements we also draw the inner walls, giving a dark
            // cut instead of a hole.
            let isClipped = localClipBounds != TileLocalClipMath.disabledBounds
            if isClipped == isBackCullingEnabled {
                isBackCullingEnabled = !isClipped
                renderEncoder.setCullMode(isBackCullingEnabled ? .back : .none)
            }

            var modelMatrix = Matrix.translationMatrix(
                x: originAndSize.x,
                y: originAndSize.y,
                z: 0
            ) * Matrix.scaleMatrix(sx: scale, sy: scale, sz: scale)
            renderEncoder.setVertexBytes(&modelMatrix, length: MemoryLayout<matrix_float4x4>.stride, index: 3)

            renderEncoder.drawIndexedPrimitives(type: .triangle,
                                                indexCount: buffers.extruded.indicesCount,
                                                indexType: .uint32,
                                                indexBuffer: extrudedIndicesBuffer,
                                                indexBufferOffset: 0)
        }
    }
}
