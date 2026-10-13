// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

enum BuildingExtrusionDrawer {
    /// Opaque building geometry with depth test and depth write, straight
    /// into the world pass. Nothing keeps tiles apart per pixel: the
    /// building coverage draws the tiles of one zoom, each in its own place
    /// (`BuildingCoveragePlanner`), so no two of them draw over the same
    /// ground.
    ///
    /// `heightScales`, index-aligned with the placements, scale each
    /// placement's heights over the ground: how far its tile has risen out
    /// of it (`ExtrusionRise`). A placement at 0 is not drawn. Empty draws
    /// every placement at full height. `liftBuffers`, index-aligned too,
    /// are each placement's buildings' lifts over the ground relief, the
    /// terrain's metres under each and the mountain share of its place
    /// (`BuildingExtrusionRenderSubsystem`), nil for a placement that
    /// stands on the plane: the world units a metre of terrain rises by
    /// over the tile this frame are bound with them, and the frame's
    /// fades and zoom (`liftFrame`), so the lifts hold at any zoom and
    /// through the relief's fade, and `liftDatumMetres`, the terrain
    /// under the point the camera looks at in the same metres
    /// (`GroundReliefStore.datumMetres`), which the lifts are drawn from.
    static func drawBuildings(renderEncoder: MTLRenderCommandEncoder,
                              cameraUniform: CameraUniform,
                              shadowBinding: ShadowReceiverBinding,
                              placeTilesContext: PlaceTilesContext,
                              indexBuffers: HiddenBuildingIndexBuffers,
                              flatRenderState: FlatRenderState,
                              heightScales: [Float] = [],
                              liftBuffers: [MTLBuffer?] = [],
                              liftDatumMetres: Float = 0,
                              liftFrame: GroundReliefFrame = .plain,
                              extrudedTilePipeline: ExtrudedTilePipeline,
                              extrudedStencilTestState: MTLDepthStencilState,
                              depthDisabledState: MTLDepthStencilState) {
        var cameraUniformValue = cameraUniform
        // The walls and lids are wound clockwise on purpose (the exterior
        // ring is forced clockwise in BuildingExtrusionMeshBuilder and the
        // lids match it), so their front face is Metal's
        // default. Declared here rather than inherited: the tile drawers in
        // the same encoder declare counter-clockwise for the ground.
        renderEncoder.setFrontFacing(.clockwise)
        renderEncoder.setCullMode(.back)

        extrudedTilePipeline.selectPipeline(renderEncoder: renderEncoder)
        renderEncoder.setDepthStencilState(extrudedStencilTestState)
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

        drawExtrudedSources(renderEncoder: renderEncoder,
                            placeTilesContext: placeTilesContext,
                            indexBuffers: indexBuffers,
                            flatRenderState: flatRenderState,
                            heightScales: heightScales,
                            liftBuffers: liftBuffers,
                            liftDatumMetres: liftDatumMetres,
                            liftFrame: liftFrame,
                            extrudedTilePipeline: extrudedTilePipeline)

        renderEncoder.setCullMode(.none)
        renderEncoder.setDepthStencilState(depthDisabledState)
    }

    /// Same geometry replayed depth-only from the light's orthographic
    /// camera, one draw per geometry (one window, so nothing to instance
    /// over). Cull `.none`: winding juggling is
    /// pointless in a depth-only pass, and drawing both faces partially
    /// covers the wall quads missing on tile boundaries. No encoder depth
    /// bias: the receiver-side bias is computed per frame from the actual
    /// texel footprint (ShadowFrameStateResolver), which keeps shadows
    /// attached to building bases. Depth clamp (pancaking) keeps casters
    /// taller than the fitted near plane instead of clipping them away.
    static func drawShadowCasters(renderEncoder: MTLRenderCommandEncoder,
                                  lightProjectionView: matrix_float4x4,
                                  placeTilesContext: PlaceTilesContext,
                                  indexBuffers: HiddenBuildingIndexBuffers,
                                  flatRenderState: FlatRenderState,
                                  heightScales: [Float] = [],
                                  liftBuffers: [MTLBuffer?] = [],
                                  liftDatumMetres: Float = 0,
                                  liftFrame: GroundReliefFrame = .plain,
                                  extrudedTilePipeline: ExtrudedTilePipeline,
                                  extrudedDepthState: MTLDepthStencilState) {
        renderEncoder.setCullMode(.none)
        extrudedTilePipeline.selectShadowPipeline(renderEncoder: renderEncoder)
        renderEncoder.setDepthStencilState(extrudedDepthState)
        renderEncoder.setDepthClipMode(.clamp)
        var castersValue = ShadowCasterUniform(lightProjectionView: lightProjectionView)
        renderEncoder.setVertexBytes(&castersValue, length: MemoryLayout<ShadowCasterUniform>.stride, index: 1)
        drawClippedCasterGeometry(renderEncoder: renderEncoder,
                                  placeTilesContext: placeTilesContext,
                                  indexBuffers: indexBuffers,
                                  flatRenderState: flatRenderState,
                                  heightScales: heightScales,
                                  liftBuffers: liftBuffers,
                                  liftDatumMetres: liftDatumMetres,
                                  liftFrame: liftFrame,
                                  extrudedTilePipeline: extrudedTilePipeline)
        renderEncoder.setDepthClipMode(.clip)
    }

    /// World-pass building draws, one per placement, whole, with back-face
    /// culling on. The buildings a model stands in for are left out of
    /// each tile's draw (`indexBuffers`).
    private static func drawExtrudedSources(renderEncoder: MTLRenderCommandEncoder,
                                            placeTilesContext: PlaceTilesContext,
                                            indexBuffers: HiddenBuildingIndexBuffers,
                                            flatRenderState: FlatRenderState,
                                            heightScales: [Float],
                                            liftBuffers: [MTLBuffer?],
                                            liftDatumMetres: Float,
                                            liftFrame: GroundReliefFrame,
                                            extrudedTilePipeline: ExtrudedTilePipeline) {
        var selectedRelief = false
        for (placementIndex, placeTile) in placeTilesContext.tilePlacements.enumerated() {
            let heightScale = placementIndex < heightScales.count ? heightScales[placementIndex] : 1
            guard heightScale > 0 else { continue }
            // The relief variant with the tile's lifts for a tile whose
            // terrain is in, the plain one for the rest.
            let liftBuffer = placementIndex < liftBuffers.count ? liftBuffers[placementIndex] : nil
            if (liftBuffer != nil) != selectedRelief {
                selectedRelief = liftBuffer != nil
                extrudedTilePipeline.selectPipeline(renderEncoder: renderEncoder, relief: selectedRelief)
            }
            if let liftBuffer {
                bindLifts(liftBuffer, tile: placeTile.metalTile.tile, datumMetres: liftDatumMetres,
                          frame: liftFrame, flatRenderState: flatRenderState, renderEncoder: renderEncoder)
            }
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
                                                                             worldWrap: placeIn.worldWrap,
                                                                             flatRenderPan: flatRenderState.pan,
                                                                             renderMapSize: flatRenderState.renderMapSize)
            let scale = originAndSize.z / 4096.0


            renderEncoder.setVertexBuffer(extrudedVertices.buffer, offset: extrudedVertices.offset, index: 0)
            renderEncoder.setVertexBuffer(extrudedStyles.buffer, offset: extrudedStyles.offset, index: 2)
            // The surface mask bit the state writes where the building lands;
            // the priority below it is not tested any more (the building
            // coverage never overlaps), it only keeps the reference shaped
            // like every other tile pass's.
            renderEncoder.setStencilReferenceValue(TileSourceStencilPriority.reference(sourceZoom: tile.z)
                                                   | TileSourceStencilPriority.surfaceMaskBit)

            var modelMatrix = Matrix.translationMatrix(
                x: originAndSize.x,
                y: originAndSize.y,
                z: 0
            ) * Matrix.scaleMatrix(sx: scale, sy: scale, sz: scale * heightScale)
            renderEncoder.setVertexBytes(&modelMatrix, length: MemoryLayout<matrix_float4x4>.stride, index: 3)

            drawIndices(of: metalTile,
                        indices: extrudedIndices,
                        indexBuffers: indexBuffers,
                        renderEncoder: renderEncoder)
        }
    }

    /// A tile's lifts, the terrain's metres and the mountain share per
    /// building, at vertex buffer 4, and at buffer 5 the world units a
    /// metre of terrain rises by at the tile's latitude this frame, the
    /// datum the lifts are drawn from, and the frame's fades and zoom.
    private static func bindLifts(_ liftBuffer: MTLBuffer,
                                  tile: Tile,
                                  datumMetres: Float,
                                  frame: GroundReliefFrame,
                                  flatRenderState: FlatRenderState,
                                  renderEncoder: MTLRenderCommandEncoder) {
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: (Double(tile.y) + 0.5) / Double(1 << tile.z))
        let unitsPerMetre = Float(ImmersiveMapProjection.worldUnitsPerMeter(latitudeRadians: latitude,
                                                                            renderMapSize: flatRenderState.renderMapSize))
        var lift = BuildingLiftUniform(unitsPerMetre: unitsPerMetre, datumMetres: datumMetres, frame: frame)
        renderEncoder.setVertexBuffer(liftBuffer, offset: 0, index: 4)
        renderEncoder.setVertexBytes(&lift, length: MemoryLayout<BuildingLiftUniform>.stride, index: 5)
    }

    /// The tile's buildings in one draw: from the tile's own index buffer,
    /// or from its working buffer when the frame leaves some buildings out
    /// (`HiddenBuildingIndexBuffers`).
    private static func drawIndices(of metalTile: MetalTile,
                                    indices: TileBufferView,
                                    indexBuffers: HiddenBuildingIndexBuffers,
                                    renderEncoder: MTLRenderCommandEncoder) {
        let extruded = metalTile.tileBuffers.extruded
        switch indexBuffers.indices(of: metalTile) {
        case .whole:
            renderEncoder.drawIndexedPrimitives(type: .triangle,
                                                indexCount: indices.count,
                                                indexType: extruded.indexType,
                                                indexBuffer: indices.buffer,
                                                indexBufferOffset: indices.offset)
        case .working(let buffer, let indexCount):
            renderEncoder.drawIndexedPrimitives(type: .triangle,
                                                indexCount: indexCount,
                                                indexType: extruded.indexType,
                                                indexBuffer: buffer,
                                                indexBufferOffset: 0)
        case .none:
            break
        }
    }

    /// Shadow-caster draws: per placement, exactly what the world pass
    /// draws of it: a building the frame leaves out casts no shadow either.
    private static func drawClippedCasterGeometry(renderEncoder: MTLRenderCommandEncoder,
                                                  placeTilesContext: PlaceTilesContext,
                                                  indexBuffers: HiddenBuildingIndexBuffers,
                                                  flatRenderState: FlatRenderState,
                                                  heightScales: [Float],
                                                  liftBuffers: [MTLBuffer?],
                                                  liftDatumMetres: Float,
                                                  liftFrame: GroundReliefFrame,
                                                  extrudedTilePipeline: ExtrudedTilePipeline) {
        var selectedRelief = false
        for (placementIndex, placeTile) in placeTilesContext.tilePlacements.enumerated() {
            let heightScale = placementIndex < heightScales.count ? heightScales[placementIndex] : 1
            guard heightScale > 0 else { continue }
            let liftBuffer = placementIndex < liftBuffers.count ? liftBuffers[placementIndex] : nil
            if (liftBuffer != nil) != selectedRelief {
                selectedRelief = liftBuffer != nil
                extrudedTilePipeline.selectShadowPipeline(renderEncoder: renderEncoder, relief: selectedRelief)
            }
            if let liftBuffer {
                bindLifts(liftBuffer, tile: placeTile.metalTile.tile, datumMetres: liftDatumMetres,
                          frame: liftFrame, flatRenderState: flatRenderState, renderEncoder: renderEncoder)
            }
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
                                                                             worldWrap: placeIn.worldWrap,
                                                                             flatRenderPan: flatRenderState.pan,
                                                                             renderMapSize: flatRenderState.renderMapSize)
            let scale = originAndSize.z / 4096.0

            renderEncoder.setVertexBuffer(extrudedVertices.buffer, offset: extrudedVertices.offset, index: 0)
            renderEncoder.setVertexBuffer(extrudedStyles.buffer, offset: extrudedStyles.offset, index: 2)

            var modelMatrix = Matrix.translationMatrix(
                x: originAndSize.x,
                y: originAndSize.y,
                z: 0
            ) * Matrix.scaleMatrix(sx: scale, sy: scale, sz: scale * heightScale)
            renderEncoder.setVertexBytes(&modelMatrix, length: MemoryLayout<matrix_float4x4>.stride, index: 3)

            drawIndices(of: metalTile,
                        indices: extrudedIndices,
                        indexBuffers: indexBuffers,
                        renderEncoder: renderEncoder)
        }
    }
}

/// Mirror of `BuildingLift` in TileExtruded.metal (vertex buffer 5): the
/// world units a metre spans over the tile, the datum in metres that the
/// tile's lifts are drawn from, and the frame's fades, zoom and strength
/// scale (`GroundReliefFrame`), as the ground's `GroundReliefUniform`.
struct BuildingLiftUniform {
    var unitsPerMetre: Float
    var datumMetres: Float
    var padding = SIMD2<Float>(repeating: 0)
    var fades: SIMD4<Float>
    var frame: SIMD4<Float>

    init(unitsPerMetre: Float, datumMetres: Float, frame: GroundReliefFrame) {
        self.unitsPerMetre = unitsPerMetre
        self.datumMetres = datumMetres
        fades = SIMD4<Float>(frame.flat.x, frame.flat.y, frame.mountain.x, frame.mountain.y)
        self.frame = SIMD4<Float>(frame.cameraZoom, frame.strengthScale, 0, 0)
    }
}
