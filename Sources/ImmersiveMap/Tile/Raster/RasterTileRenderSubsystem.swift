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
/// and rises by the ground relief where the frame is on it
/// (`GroundReliefStore`), on a grid as fine as the zoom's flattening grid.
/// On the sphere it follows the unroll as the sphere's tiles do.
final class RasterTileRenderSubsystem: RenderSubsystem {
    let name: String = "RasterTiles"

    private let pipeline: RasterTilePipeline
    private let grid: RasterTileGrid
    private let sampler: MTLSamplerState?
    private let mipLevelBias: Float
    private let groundSlotOwnerState: MTLDepthStencilState
    private let sphereOpaqueOwnerState: MTLDepthStencilState
    private let depthDisabledState: MTLDepthStencilState
    private let debugOverlayControls: DebugOverlayControlState
    private let groundShadowMaskTextureProvider: () -> MTLTexture?
    private let groundShadowMaskFallbackTexture: MTLTexture
    private let groundReliefStore: GroundReliefStore?
    private let groundFlattening: ImmersiveMapSettings.TileSettings.GroundFlatteningSettings

    init(device: MTLDevice,
         pipeline: RasterTilePipeline,
         settings: ImmersiveMapSettings.TileSettings.RasterizationSettings,
         groundSlotOwnerState: MTLDepthStencilState,
         sphereOpaqueOwnerState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState,
         debugOverlayControls: DebugOverlayControlState,
         groundShadowMaskTextureProvider: @escaping () -> MTLTexture?,
         groundShadowMaskFallbackTexture: MTLTexture,
         groundReliefStore: GroundReliefStore? = nil,
         groundFlattening: ImmersiveMapSettings.TileSettings.GroundFlatteningSettings = .init()) {
        self.pipeline = pipeline
        self.groundReliefStore = groundReliefStore
        self.groundFlattening = groundFlattening
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
        self.groundSlotOwnerState = groundSlotOwnerState
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
        encoder.setDepthStencilState(groundSlotOwnerState)
        var cameraUniform = frameContext.cameraUniform
        encoder.setVertexBytes(&cameraUniform, length: MemoryLayout<CameraUniform>.stride, index: 1)
        let groundShadowMask = GroundShadowMaskBinding.resolve(frameContext: frameContext,
                                                               maskTexture: groundShadowMaskTextureProvider(),
                                                               fallbackTexture: groundShadowMaskFallbackTexture)
        var shadowUniform = groundShadowMask.uniform
        encoder.setFragmentBytes(&shadowUniform, length: MemoryLayout<ShadowUniform>.stride, index: 3)
        encoder.setFragmentTexture(groundShadowMask.texture, index: 1)
        GroundFogUniform.bind(GroundFogUniform.resolve(frameContext: frameContext), encoder: encoder)
        let flatRenderState = frameContext.resolvedPresentation.flatRenderState
        // A placement draws its slot's ground only (`GroundSlotClip`), the
        // depth alone ordering the tiles: an ancestor standing in draws
        // around the descendants placed in the same slot.
        let rings = GroundSlotClip.Rings(targetZoom: frameContext.visibleContent.tileZoomLevel,
                                         bands: frameContext.visibleContent.flatRingBands,
                                         flatRenderState: flatRenderState)
        var descendantsBySlot: [VisibleTile: [Tile]] = [:]
        for placement in placements where placement.placeIn.tile != placement.slot.tile && placement.placeIn.tile.z > placement.slot.z {
            descendantsBySlot[placement.slot, default: []].append(placement.placeIn.tile)
        }
        var clipRect = GroundSlotClip.unclipped
        // The relief variant for a tile whose terrain is in, the plain one
        // for the rest, selected only where it changes from the last draw.
        var selectedRelief = false
        for placement in placements {
            let tile = placement.placeIn.tile
            let relief = groundReliefStore?.relief(for: tile,
                                                   terrainZoom: GroundReliefStore.terrainZoom(forTargetZoom: placement.targetZoom))
            let cells = relief == nil ? 0 : groundFlattening.grid(forTileZoom: tile.z)
            guard let mesh = grid.mesh(forTileZoom: tile.z, atLeast: cells) else { continue }
            if (relief != nil) != selectedRelief {
                selectedRelief = relief != nil
                encoder.setRenderPipelineState(selectedRelief ? pipeline.flatReliefPipelineState : pipeline.flatPipelineState)
            }
            if let relief, let groundReliefStore {
                var uniform = GroundReliefUniform(origin: relief.origin,
                                                  scale: relief.scale,
                                                  worldUnitsPerMetre: groundReliefStore.worldUnitsPerMetre(over: tile,
                                                                                                           renderMapSize: flatRenderState.renderMapSize),
                                                  datumMetres: groundReliefStore.datumMetres)
                encoder.setVertexTexture(relief.texture, index: 0)
                encoder.setVertexBytes(&uniform, length: MemoryLayout<GroundReliefUniform>.stride, index: 9)
            }
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
            let holes = tile.z < placement.slot.z ? descendantsBySlot[placement.slot] ?? [] : []
            for rect in GroundSlotClip.rects(source: tile, slot: placement.slot, holes: holes, rings: rings) {
                clipRect = rect
                encoder.setVertexBytes(&clipRect, length: MemoryLayout<SIMD4<Float>>.stride, index: 12)
                draw(placement: placement, mesh: mesh, encoder: encoder)
            }
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
            // The sphere's tile-priority mark (TileSourceStencilPriority).
            encoder.setStencilReferenceValue(TileSourceStencilPriority.reference(sourceZoom: tile.z))
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
