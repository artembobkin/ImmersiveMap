// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

enum BuildingExtrusionDrawer {
    /// Opaque building geometry with depth test and depth write:
    /// solid mode draws it straight into the world pass, translucent into the
    /// offscreen building image.
    static func drawBuildings(renderEncoder: MTLRenderCommandEncoder,
                              cameraUniform: CameraUniform,
                              shadowBinding: ShadowReceiverBinding,
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

        var shadowUniformValue = shadowBinding.uniform
        renderEncoder.setFragmentBytes(&shadowUniformValue, length: MemoryLayout<ShadowUniform>.stride, index: 5)
        renderEncoder.setFragmentTexture(shadowBinding.texture, index: 0)

        // World-units-per-meter along z for the depth-cue vertical gradient.
        // Local vertex z = meters * 2^(tileZoom - anchorZoom) and the model
        // matrix scales by renderMapSize / (4096 * 2^tileZoom), so the tile
        // zoom cancels and one per-frame constant serves every tile (assumes
        // the default style extrusionAnchorZoom of 16; a style with a custom
        // anchor shifts the gradient proportionally, which is only a tonal
        // cue).
        var metersToWorldZ = Float(flatRenderState.renderMapSize / (4096.0 * 65536.0))
        renderEncoder.setFragmentBytes(&metersToWorldZ, length: MemoryLayout<Float>.stride, index: 6)

        drawExtrudedGeometry(renderEncoder: renderEncoder,
                             placeTilesContext: placeTilesContext,
                             flatRenderState: flatRenderState)

        renderEncoder.setCullMode(.none)
        renderEncoder.setDepthStencilState(depthDisabledState)
    }

    /// Same geometry replayed depth-only from the light's orthographic
    /// cameras into the two halves of the shadow atlas (viewport + scissor per
    /// cascade). Cull `.none`: winding juggling is pointless in a depth-only
    /// pass, and drawing both faces partially covers the wall quads missing on
    /// tile boundaries. No encoder depth bias — the receiver-side bias is
    /// computed per frame from the actual texel footprint
    /// (ShadowFrameStateResolver), which keeps shadows attached to building
    /// bases. Depth clamp (pancaking) keeps casters taller than the fitted
    /// near plane instead of clipping them away.
    static func drawShadowCasters(renderEncoder: MTLRenderCommandEncoder,
                                  lightProjectionViews: [matrix_float4x4],
                                  mapResolution: Int,
                                  placeTilesContext: PlaceTilesContext,
                                  flatRenderState: FlatRenderState,
                                  extrudedTilePipeline: ExtrudedTilePipeline,
                                  extrudedDepthState: MTLDepthStencilState) {
        renderEncoder.setCullMode(.none)
        extrudedTilePipeline.selectShadowPipeline(renderEncoder: renderEncoder)
        renderEncoder.setDepthStencilState(extrudedDepthState)
        renderEncoder.setDepthClipMode(.clamp)
        for (cascadeIndex, lightProjectionView) in lightProjectionViews.enumerated() {
            ShadowCascadeAtlas.selectCascade(renderEncoder: renderEncoder,
                                             cascadeIndex: cascadeIndex,
                                             mapResolution: mapResolution)
            var cameraUniformValue = CameraUniform(matrix: lightProjectionView, eye: .zero, padding: 0)
            renderEncoder.setVertexBytes(&cameraUniformValue, length: MemoryLayout<CameraUniform>.stride, index: 1)
            drawExtrudedGeometry(renderEncoder: renderEncoder,
                                 placeTilesContext: placeTilesContext,
                                 flatRenderState: flatRenderState,
                                 usesBackFaceCulling: false)
        }
        renderEncoder.setDepthClipMode(.clip)
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
                                             flatRenderState: FlatRenderState,
                                             usesBackFaceCulling: Bool = true) {
        var isBackCullingEnabled = usesBackFaceCulling
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
            if usesBackFaceCulling, isClipped == isBackCullingEnabled {
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
