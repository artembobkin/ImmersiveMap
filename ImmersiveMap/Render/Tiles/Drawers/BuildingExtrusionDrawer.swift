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
                              depthDisabledState: MTLDepthStencilState,
                              intoImageAttachment: Bool = false) {
        var cameraUniformValue = cameraUniform
        // The walls and roofs are wound clockwise on purpose (the exterior
        // ring is forced clockwise in TileMvtParser+Helpers and the roofs
        // match it in RoofGeometryBuilder), so their front face is Metal's
        // default. Declared here rather than inherited: the tile drawers in
        // the same encoder declare counter-clockwise for the ground.
        renderEncoder.setFrontFacing(.clockwise)
        renderEncoder.setCullMode(.back)

        if intoImageAttachment {
            extrudedTilePipeline.selectIntoImagePipeline(renderEncoder: renderEncoder)
        } else {
            extrudedTilePipeline.selectPipeline(renderEncoder: renderEncoder)
        }
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
    /// cameras, all cascades in one pass: every draw carries
    /// `instanceCount = cascadeCount` and the vertex stage routes each
    /// instance to its cascade's array slice, so the geometry is encoded
    /// once instead of once per cascade. Cull `.none`: winding juggling is
    /// pointless in a depth-only pass, and drawing both faces partially
    /// covers the wall quads missing on tile boundaries. No encoder depth
    /// bias: the receiver-side bias is computed per frame from the actual
    /// texel footprint (ShadowFrameStateResolver), which keeps shadows
    /// attached to building bases. Depth clamp (pancaking) keeps casters
    /// taller than the fitted near plane instead of clipping them away.
    static func drawShadowCasters(renderEncoder: MTLRenderCommandEncoder,
                                  lightProjectionViews: [matrix_float4x4],
                                  placeTilesContext: PlaceTilesContext,
                                  flatRenderState: FlatRenderState,
                                  extrudedTilePipeline: ExtrudedTilePipeline,
                                  extrudedDepthState: MTLDepthStencilState) {
        renderEncoder.setCullMode(.none)
        extrudedTilePipeline.selectShadowPipeline(renderEncoder: renderEncoder)
        renderEncoder.setDepthStencilState(extrudedDepthState)
        renderEncoder.setDepthClipMode(.clamp)
        var castersValue = ShadowCasterUniform(lightProjectionViews: lightProjectionViews)
        renderEncoder.setVertexBytes(&castersValue, length: MemoryLayout<ShadowCasterUniform>.stride, index: 1)
        drawExtrudedGeometry(renderEncoder: renderEncoder,
                             placeTilesContext: placeTilesContext,
                             flatRenderState: flatRenderState,
                             usesBackFaceCulling: false,
                             instanceCount: ShadowCascadeAtlas.cascadeCount)
        renderEncoder.setDepthClipMode(.clip)
    }

    /// Framebuffer-fetch composite: one fullscreen triangle that reads the
    /// in-pass building attachment per sample, blends it over the map with
    /// the shared alpha, and writes the far plane back into depth (see the
    /// shader for the exact semantics contract).
    static func drawCompositeFetch(renderEncoder: MTLRenderCommandEncoder,
                                   alpha: Float,
                                   extrudedTilePipeline: ExtrudedTilePipeline,
                                   compositeDepthResetState: MTLDepthStencilState,
                                   depthDisabledState: MTLDepthStencilState) {
        renderEncoder.setCullMode(.none)
        extrudedTilePipeline.selectCompositeFetchPipeline(renderEncoder: renderEncoder)
        renderEncoder.setDepthStencilState(compositeDepthResetState)
        var alphaValue = alpha
        renderEncoder.setFragmentBytes(&alphaValue, length: MemoryLayout<Float>.stride, index: 0)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
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
                                             flatRenderState: FlatRenderState,
                                             usesBackFaceCulling: Bool = true,
                                             instanceCount: Int = 1) {
        var isBackCullingEnabled = usesBackFaceCulling
        for placeTile in placeTilesContext.tilePlacements {
            let metalTile = placeTile.metalTile
            let tile = metalTile.tile
            let buffers = metalTile.tileBuffers
            let placeIn = placeTile.placeIn

            guard buffers.extruded.indicesCount > 0,
                  let extrudedIndices = buffers.extruded.indices,
                  let extrudedVertices = buffers.extruded.vertices,
                  let extrudedStyles = buffers.extruded.styles else { continue }

            let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.x,
                                                                             y: tile.y,
                                                                             z: tile.z,
                                                                             loop: placeIn.loop,
                                                                             flatRenderPan: flatRenderState.pan,
                                                                             renderMapSize: flatRenderState.renderMapSize)
            let scale = originAndSize.z / 4096.0

            renderEncoder.setVertexBuffer(extrudedVertices.buffer, offset: extrudedVertices.offset, index: 0)
            renderEncoder.setVertexBuffer(extrudedStyles.buffer, offset: extrudedStyles.offset, index: 2)

            // Clip the geometry to the placeIn slot (clip distances in the
            // vertex stage, for the main and the shadow-caster path alike):
            // buildings of a retained parent must not overlap neighboring
            // exact tiles, nor cast shadows over them.
            var localClipBounds = TileLocalClipMath.clipBounds(source: tile, placeIn: placeIn.tile)
            renderEncoder.setVertexBytes(&localClipBounds,
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
                                                indexCount: extrudedIndices.count,
                                                indexType: buffers.extruded.indexType,
                                                indexBuffer: extrudedIndices.buffer,
                                                indexBufferOffset: extrudedIndices.offset,
                                                instanceCount: instanceCount)
        }
    }
}
