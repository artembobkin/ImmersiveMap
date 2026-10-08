// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// The ground of the raster targets (`TilePlacementState.rasterPlacements`):
/// each texture on its tile's grid (`RasterTileGrid`), first in the ground's
/// layer on either surface, before the vector ground. A texture is opaque
/// and owns its pixels as an opaque fill does: it writes the ground's first
/// rank depth and the tile-priority stencil, so the lines drawn over it
/// pass, a finer tile's ground replaces it, and a coarser one's stays out.
/// On the plane it takes the ground shadow mask as the vector ground does,
/// on the sphere it follows the unroll as the sphere's tiles do.
final class RasterTileRenderSubsystem: RenderSubsystem {
    let name: String = "RasterTiles"

    private let pipeline: RasterTilePipeline
    private let grid: RasterTileGrid
    private let sampler: MTLSamplerState?
    private let mipLevelBias: Float
    private let groundOwnerState: MTLDepthStencilState
    private let sphereOpaqueOwnerState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState
    private let debugOverlayControls: DebugOverlayControlState
    private let groundShadowMaskTextureProvider: () -> MTLTexture?
    private let groundShadowMaskFallbackTexture: MTLTexture

    init(device: MTLDevice,
         pipeline: RasterTilePipeline,
         settings: ImmersiveMapSettings.TileSettings.RasterizationSettings,
         groundOwnerState: MTLDepthStencilState,
         sphereOpaqueOwnerState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState,
         debugOverlayControls: DebugOverlayControlState,
         groundShadowMaskTextureProvider: @escaping () -> MTLTexture?,
         groundShadowMaskFallbackTexture: MTLTexture) {
        self.pipeline = pipeline
        self.grid = RasterTileGrid(device: device)
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .linear
        descriptor.maxAnisotropy = min(max(settings.maximumAnisotropy, 1), 16)
        // The edge texels repeat past the tile: a tile's mips never reach
        // into the texture's opposite side.
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        descriptor.label = "RasterTileSampler"
        self.sampler = device.makeSamplerState(descriptor: descriptor)
        self.mipLevelBias = settings.mipLevelBias
        self.groundOwnerState = groundOwnerState
        self.sphereOpaqueOwnerState = sphereOpaqueOwnerState
        self.depthDisabledState = depthDisabledState
        self.debugOverlayControls = debugOverlayControls
        self.groundShadowMaskTextureProvider = groundShadowMaskTextureProvider
        self.groundShadowMaskFallbackTexture = groundShadowMaskFallbackTexture
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext _: FrameContext, resourceRegistry _: RenderResourceRegistry) {}

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        let placements = frameContext.sharedState.tilePlacementState.rasterPlacements
        guard placements.isEmpty == false, let sampler else { return }
        switch (layer, frameContext.renderSurfaceMode) {
        case (.flatMapSurface, .flat):
            encodeFlat(placements: placements, encoder: encoder, frameContext: frameContext, sampler: sampler)
        case (.globeVectorSurface, .spherical):
            encodeSphere(placements: placements, encoder: encoder, frameContext: frameContext, sampler: sampler)
        default:
            return
        }
    }

    func handleMemoryWarning() {}

    func evict() {}

    // MARK: - Plane

    private func encodeFlat(placements: [RasterTilePlacement],
                            encoder: MTLRenderCommandEncoder,
                            frameContext: FrameContext,
                            sampler: MTLSamplerState) {
        encoder.pushDebugGroup("ground.rasterTiles")
        beginDraws(encoder: encoder, sampler: sampler)
        encoder.setRenderPipelineState(pipeline.flatPipelineState)
        encoder.setDepthStencilState(groundOwnerState)
        var cameraUniform = frameContext.cameraUniform
        encoder.setVertexBytes(&cameraUniform, length: MemoryLayout<CameraUniform>.stride, index: 1)
        let groundShadowMask = GroundShadowMaskBinding.resolve(frameContext: frameContext,
                                                               maskTexture: groundShadowMaskTextureProvider(),
                                                               fallbackTexture: groundShadowMaskFallbackTexture)
        var shadowUniform = groundShadowMask.uniform
        encoder.setFragmentBytes(&shadowUniform, length: MemoryLayout<ShadowUniform>.stride, index: 3)
        encoder.setFragmentTexture(groundShadowMask.texture, index: 1)
        let flatRenderState = frameContext.resolvedPresentation.flatRenderState
        for placement in placements {
            let tile = placement.placeIn.tile
            guard let mesh = grid.mesh(forTileZoom: tile.z) else { continue }
            let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.x,
                                                                             y: tile.y,
                                                                             z: tile.z,
                                                                             worldWrap: placement.placeIn.worldWrap,
                                                                             flatRenderPan: flatRenderState.pan,
                                                                             renderMapSize: flatRenderState.renderMapSize)
            let scale = originAndSize.z / 4096.0
            var modelMatrix = Matrix.translationMatrix(x: originAndSize.x,
                                                       y: originAndSize.y,
                                                       z: 0) * Matrix.scaleMatrix(sx: scale, sy: scale, sz: 1)
            encoder.setVertexBytes(&modelMatrix, length: MemoryLayout<matrix_float4x4>.stride, index: 3)
            draw(placement: placement, mesh: mesh, encoder: encoder)
        }
        endDraws(encoder: encoder)
        encoder.popDebugGroup()
    }

    // MARK: - Sphere

    private func encodeSphere(placements: [RasterTilePlacement],
                              encoder: MTLRenderCommandEncoder,
                              frameContext: FrameContext,
                              sampler: MTLSamplerState) {
        let globe = frameContext.globeRenderUniform
        let pureSphere = GlobeSphereVertexPath.isPureSphere(renderSurfaceMode: frameContext.renderSurfaceMode,
                                                            transition: globe.transition)
        encoder.pushDebugGroup("ground.rasterTiles")
        beginDraws(encoder: encoder, sampler: sampler)
        encoder.setRenderPipelineState(pureSphere ? pipeline.spherePurePipelineState : pipeline.sphereMorphPipelineState)
        encoder.setDepthStencilState(sphereOpaqueOwnerState)
        var cameraUniform = frameContext.cameraUniform
        var globeValue = globe
        var globeFrame = GlobeFrameConstantsUniform.make(globe: globe, cameraMatrix: frameContext.cameraUniform.matrix)
        encoder.setVertexBytes(&cameraUniform, length: MemoryLayout<CameraUniform>.stride, index: 1)
        encoder.setVertexBytes(&globeValue, length: MemoryLayout<GlobeUniform>.stride, index: 8)
        encoder.setVertexBytes(&globeFrame, length: MemoryLayout<GlobeFrameConstantsUniform>.stride, index: 10)
        // The sphere has one copy of the world: a tile two wrap copies
        // name draws once.
        var drawn = Set<RasterTileKey>()
        for placement in placements where drawn.insert(placement.key).inserted {
            let tile = placement.placeIn.tile
            guard let mesh = grid.mesh(forTileZoom: tile.z) else { continue }
            var surfaceTile = GlobeSurfaceTileUniform(tile: tile)
            encoder.setVertexBytes(&surfaceTile, length: MemoryLayout<GlobeSurfaceTileUniform>.stride, index: 9)
            draw(placement: placement, mesh: mesh, encoder: encoder)
        }
        endDraws(encoder: encoder)
        encoder.popDebugGroup()
    }

    // MARK: - Shared

    /// Every grid triangle is counter-clockwise in render space, as every
    /// tile triangle is, and neither surface mirrors: back faces are culled,
    /// which on the sphere removes its far side.
    private func beginDraws(encoder: MTLRenderCommandEncoder, sampler: MTLSamplerState) {
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.back)
        if debugOverlayControls.snapshot().wireframeEnabled {
            encoder.setTriangleFillMode(.lines)
        }
        var sampling = RasterTileSamplingUniform(mipLevelBias: mipLevelBias)
        encoder.setFragmentBytes(&sampling, length: MemoryLayout<RasterTileSamplingUniform>.stride, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
    }

    private func endDraws(encoder: MTLRenderCommandEncoder) {
        encoder.setTriangleFillMode(.fill)
        encoder.setCullMode(.none)
        encoder.setFrontFacing(.clockwise)
        encoder.setDepthStencilState(depthDisabledState)
    }

    private func draw(placement: RasterTilePlacement, mesh: RasterTileGrid.Mesh, encoder: MTLRenderCommandEncoder) {
        encoder.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
        encoder.setFragmentTexture(placement.texture, index: 0)
        encoder.setStencilReferenceValue(TileSourceStencilPriority.reference(sourceZoom: placement.placeIn.tile.z))
        encoder.drawIndexedPrimitives(type: .triangle,
                                      indexCount: mesh.indexCount,
                                      indexType: .uint16,
                                      indexBuffer: mesh.indices,
                                      indexBufferOffset: 0)
    }
}

/// Mirror of `TileRasterSampling` in TileRaster.metal (fragment buffer 1).
struct RasterTileSamplingUniform {
    var mipLevelBias: Float
}
