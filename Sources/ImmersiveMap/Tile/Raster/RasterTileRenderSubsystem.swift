// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// The ground of the raster targets, the slots of a ring rule with a raster
/// size (`VisibleContentState.rasterTiles`): the vector path with one step
/// between, a texture. The placements are the vector placements
/// (`TilePlacementState.placeTilesContext`), the targets' own tiles and
/// the descendants and ancestors standing in for them, kept and released
/// as every vector tile is. Each frame, before the world pass, every tile
/// placed in a raster slot draws its fills into a texture of the slot's
/// size (`prepareGPU`, its own render passes on the frame's command
/// buffer, the zoom fades at the frame's camera zoom as the vector ground
/// draws them, then the mip chain), and the world pass draws the texture
/// on the tile's grid (`RasterTileGrid`), first in the ground's layer on
/// either surface, before the vector ground. Nothing is kept from one
/// frame to the next but the textures themselves, a pool by size: the
/// texture is what the tile's geometry would draw this frame, every frame,
/// with no key, no bake queue and no disk behind it, so a texture is never
/// stale, never missing while its tile is in, and never a hole where the
/// vector ground would not be one.
///
/// A texture is opaque and owns its pixels as an opaque fill does: it
/// writes a depth half a rank step behind the ground's first, so the
/// lines drawn over it pass and a vector tile drawn over it wins outright
/// (TileRaster.metal), and the tile-priority stencil
/// (`TileSourceStencilPriority`), drawn at
/// full extent and finest first on either surface, so a coarser source
/// stays out of the pixels a finer one painted. On the plane it takes the
/// ground shadow mask as the vector ground does, and rises by the ground
/// relief where the frame is on it (`GroundReliefStore`), on a grid as
/// fine as the zoom's flattening grid. On the sphere it follows the
/// unroll as the sphere's tiles do.
final class RasterTileRenderSubsystem: RenderSubsystem {
    let name: String = "RasterTiles"

    /// One tile drawn into a texture this frame, and where it is drawn:
    /// once per wrap copy of the flat world it is placed at.
    private struct Source {
        let metalTile: MetalTile
        var size: Int
        var texture: MTLTexture?
        var placements: [Placement] = []
    }

    /// A wrap copy a source is drawn at, and the finest raster target it
    /// stands in there: the ring whose terrain it rises by.
    private struct Placement {
        let worldWrap: Int8
        var targetZoom: Int
    }

    private let device: MTLDevice
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
    private let groundReliefStore: GroundReliefStore?
    private let groundFlattening: ImmersiveMapSettings.TileSettings.GroundFlatteningSettings

    /// The frame's sources, by the tile drawn: on the plane in the order
    /// of their stencil references, the nearest ring's first and the
    /// finest of a ring first, on the sphere finest first.
    private var sources: [Source] = []
    /// The textures by size, reused frame after frame. A size's pool grows
    /// to what a frame needs and shrinks when a frame needs much less, so
    /// a camera that pans keeps its textures and one that zooms out of
    /// the raster rings lets them go.
    private var texturePool: [Int: [MTLTexture]] = [:]
    /// The multisampled target per size the fills are drawn through,
    /// resolved into the texture: memoryless where the GPU keeps a pass's
    /// samples on chip, so it costs no memory.
    private var multisampleTargets: [Int: MTLTexture] = [:]

    /// How many textures past a frame's need a size's pool keeps before
    /// it shrinks: the frames of a pan, where the need moves by a few.
    static let poolSlack = 16

    init(device: MTLDevice,
         pipeline: RasterTilePipeline,
         settings: ImmersiveMapSettings.TileSettings.RasterizationSettings,
         groundOwnerState: MTLDepthStencilState,
         sphereOpaqueOwnerState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState,
         debugOverlayControls: DebugOverlayControlState,
         groundShadowMaskTextureProvider: @escaping () -> MTLTexture?,
         groundShadowMaskFallbackTexture: MTLTexture,
         groundReliefStore: GroundReliefStore? = nil,
         groundFlattening: ImmersiveMapSettings.TileSettings.GroundFlatteningSettings = .init()) {
        self.device = device
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
        self.groundOwnerState = groundOwnerState
        self.sphereOpaqueOwnerState = sphereOpaqueOwnerState
        self.depthDisabledState = depthDisabledState
        self.debugOverlayControls = debugOverlayControls
        self.groundShadowMaskTextureProvider = groundShadowMaskTextureProvider
        self.groundShadowMaskFallbackTexture = groundShadowMaskFallbackTexture
    }

    // MARK: - The frame's sources

    /// The frame's raster placements, grouped by the tile drawn: a tile
    /// placed in several raster slots draws into one texture, of the
    /// largest size among them, and is drawn once per wrap copy it is
    /// placed at, at full extent. On the plane the placement prepass has
    /// settled which source a pixel shows (`FlatTileStencilPacking`), and
    /// the sources are ordered finest first for the pipeline's sake; on
    /// the sphere finest first, which the tile-priority stencil reads.
    func update(frameContext: FrameContext) {
        let placements = frameContext.sharedState.tilePlacementState.placeTilesContext.tilePlacements
        sources.removeAll(keepingCapacity: true)
        guard placements.contains(where: { $0.rules.raster != nil }) else {
            trimPools(needed: [:])
            return
        }
        // A source has one representation a frame: a tile drawn as
        // geometry anywhere (a stand-in carrying the vector rules it was
        // shown with, `TilePlacementPlanner`) draws no texture, its
        // geometry at full extent covers its raster slots too. Drawn both
        // ways, the two would share one stencil mark and meet by depth,
        // which on a relief, where their meshes sample the terrain apart,
        // leaves patches of each.
        let vectorTiles = Set(placements.filter { $0.rules.raster == nil }.map(\.metalTile.tile))
        var indexByTile: [Tile: Int] = [:]
        for placeTile in placements {
            // A raster placement (`TileDrawRules.raster`): a raster slot's
            // own tile, or a stand-in drawn as its own raster slot draws it.
            guard let target = placeTile.rules.raster, vectorTiles.contains(placeTile.metalTile.tile) == false else { continue }
            let tile = placeTile.metalTile.tile
            let index: Int
            if let found = indexByTile[tile] {
                index = found
                sources[index].size = max(sources[index].size, target.size)
            } else {
                index = sources.count
                indexByTile[tile] = index
                sources.append(Source(metalTile: placeTile.metalTile, size: target.size))
            }
            let worldWrap = placeTile.placeIn.worldWrap
            if let placement = sources[index].placements.firstIndex(where: { $0.worldWrap == worldWrap }) {
                sources[index].placements[placement].targetZoom = max(sources[index].placements[placement].targetZoom,
                                                                      placeTile.slot.z)
            } else {
                sources[index].placements.append(Placement(worldWrap: worldWrap, targetZoom: placeTile.slot.z))
            }
        }
        if frameContext.renderSurfaceMode == .flat {
            sources.sort { Self.reference(of: $0) > Self.reference(of: $1) }
        } else {
            sources.sort { $0.metalTile.tile.z > $1.metalTile.tile.z }
        }
        // A texture for each, from the pool of its size.
        var needed: [Int: Int] = [:]
        for index in sources.indices {
            let size = sources[index].size
            let used = needed[size, default: 0]
            needed[size] = used + 1
            sources[index].texture = texture(size: size, index: used)
        }
        trimPools(needed: needed)
    }

    /// The plane's stencil value of a source (`FlatTileStencilPacking`).
    private static func reference(of source: Source) -> UInt32 {
        FlatTileStencilPacking.reference(sourceZoom: source.metalTile.tile.z)
    }

    private func texture(size: Int, index: Int) -> MTLTexture? {
        var pool = texturePool[size] ?? []
        while pool.count <= index {
            guard let texture = RasterTileTexture.make(device: device, size: size) else { return nil }
            pool.append(texture)
        }
        texturePool[size] = pool
        return pool[index]
    }

    /// Lets go of the textures a frame needs far fewer of than a size's
    /// pool holds, and of every size no raster slot asks for.
    private func trimPools(needed: [Int: Int]) {
        for size in Array(texturePool.keys) {
            let count = needed[size] ?? 0
            guard count > 0 else {
                texturePool[size] = nil
                multisampleTargets[size] = nil
                continue
            }
            if let pool = texturePool[size], pool.count > count + Self.poolSlack {
                texturePool[size] = Array(pool.prefix(count + Self.poolSlack))
            }
        }
    }

    // MARK: - The textures

    /// Draws every source's fills into its texture: one pass per texture
    /// on the frame's command buffer, through the multisampled target of
    /// its size, then the mip chains in one blit. The zoom fades are the
    /// frame's camera zoom's, as the vector ground draws them.
    func prepareGPU(frameContext: FrameContext, resourceRegistry _: RenderResourceRegistry) {
        guard sources.isEmpty == false, let commandBuffer = frameContext.commandBuffer else { return }
        let base = frameContext.services.baseColors.map
        let clearColor = MTLClearColor(red: Double(base.x), green: Double(base.y), blue: Double(base.z), alpha: 1)
        var fade = TileOverviewFadeUniform(pixelsPerPoint: 1, cameraZoom: Float(frameContext.animatedZoom))
        var drawn: [MTLTexture] = []
        drawn.reserveCapacity(sources.count)
        for source in sources {
            guard let texture = source.texture, let target = multisampleTarget(size: source.size) else { continue }
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = target
            descriptor.colorAttachments[0].resolveTexture = texture
            descriptor.colorAttachments[0].resolveLevel = 0
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].clearColor = clearColor
            descriptor.colorAttachments[0].storeAction = .multisampleResolve
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { continue }
            let tile = source.metalTile.tile
            encoder.label = "RasterTile \(tile.z)/\(tile.x)/\(tile.y)"
            encoder.setRenderPipelineState(pipeline.bakePipelineState)
            encoder.setCullMode(.none)
            Self.encodeFills(of: source.metalTile.tileBuffers.ground, fade: &fade, encoder: encoder)
            encoder.endEncoding()
            drawn.append(texture)
        }
        guard drawn.isEmpty == false, let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.label = "RasterTileMipmaps"
        for texture in drawn {
            blit.generateMipmaps(for: texture)
        }
        blit.endEncoding()
    }

    /// The fill runs of a ground layer, in buffer order (bottom to top),
    /// adjacent runs in one draw. The ribbons are left out: the lines are
    /// never in a raster tile. A run faded out at the frame's zoom is left
    /// out, as the vector ground leaves it out, and the rest take their
    /// fade's alpha in the shader. A layer without a run table draws
    /// nothing, as the vector ground's class passes do.
    private static func encodeFills(of ground: TileBuffers.GeometryLayer,
                                    fade: inout TileOverviewFadeUniform,
                                    encoder: MTLRenderCommandEncoder) {
        guard ground.indicesCount > 0,
              let indices = ground.indices,
              let vertices = ground.vertices,
              let styles = ground.styles,
              let styleZoomFade = ground.styleZoomFade else { return }
        encoder.setVertexBuffer(vertices.buffer, offset: vertices.offset, index: 0)
        encoder.setVertexBuffer(styles.buffer, offset: styles.offset, index: 2)
        encoder.setVertexBuffer(styleZoomFade.buffer, offset: styleZoomFade.offset, index: 4)
        encoder.setVertexBytes(&fade, length: MemoryLayout<TileOverviewFadeUniform>.stride, index: 11)
        let indexByteWidth = ground.indexType == .uint16 ? 2 : 4
        var spanStart = 0
        var spanCount = 0
        func flush() {
            guard spanCount > 0 else { return }
            encoder.drawIndexedPrimitives(type: .triangle,
                                          indexCount: spanCount,
                                          indexType: ground.indexType,
                                          indexBuffer: indices.buffer,
                                          indexBufferOffset: indices.offset + spanStart * indexByteWidth)
            spanCount = 0
        }
        for run in ground.styleRuns {
            guard run.indexCount > 0,
                  run.isFillsClass,
                  TileStyleFadeMath.fadeIsZero(zoomFade: run.zoomFade, overviewFade: fade) == false else {
                flush()
                continue
            }
            if spanCount > 0, spanStart + spanCount == Int(run.indexStart) {
                spanCount += Int(run.indexCount)
            } else {
                flush()
                spanStart = Int(run.indexStart)
                spanCount = Int(run.indexCount)
            }
        }
        flush()
    }

    private func multisampleTarget(size: Int) -> MTLTexture? {
        if let target = multisampleTargets[size] {
            return target
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RasterTileTexture.pixelFormat,
                                                                  width: size,
                                                                  height: size,
                                                                  mipmapped: false)
        descriptor.textureType = .type2DMultisample
        descriptor.sampleCount = RasterTilePipeline.bakeSampleCount
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = device.supportsFamily(.apple2) ? .memoryless : .private
        let target = device.makeTexture(descriptor: descriptor)
        target?.label = "RasterTileSamples.\(size)"
        multisampleTargets[size] = target
        return target
    }

    // MARK: - The draws

    func encode(layer: RenderLayer, encoder: MTLRenderCommandEncoder, frameContext: FrameContext) {
        guard sources.isEmpty == false, let sampler else { return }
        switch (layer, frameContext.renderSurfaceMode) {
        case (.flatMapSurface, .flat):
            encodeFlat(encoder: encoder, frameContext: frameContext, sampler: sampler)
        case (.globeVectorSurface, .spherical):
            encodeSphere(encoder: encoder, frameContext: frameContext, sampler: sampler)
        default:
            return
        }
    }

    func handleMemoryWarning() {
        texturePool.removeAll()
        multisampleTargets.removeAll()
    }

    func evict() {
        sources.removeAll()
        texturePool.removeAll()
        multisampleTargets.removeAll()
    }

    private func encodeFlat(encoder: MTLRenderCommandEncoder,
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
        GroundFogUniform.bind(GroundFogUniform.resolve(frameContext: frameContext), encoder: encoder)
        let flatRenderState = frameContext.resolvedPresentation.flatRenderState
        // The relief variant for a tile whose terrain is in, the plain one
        // for the rest, selected only where it changes from the last draw.
        var selectedRelief = false
        for source in sources {
            guard let texture = source.texture else { continue }
            let tile = source.metalTile.tile
            encoder.setFragmentTexture(texture, index: 0)
            // The tile-priority value, the tile's zoom, tested equal to
            // the planner's marks (FlatTileStencilPacking).
            encoder.setStencilReferenceValue(Self.reference(of: source))
            for placement in source.placements {
                let relief = groundReliefStore?.relief(for: tile,
                                                       terrainZoom: GroundReliefStore.terrainZoom(forTargetZoom: placement.targetZoom))
                let cells = relief == nil ? 0 : groundFlattening.grid(forTileZoom: tile.z)
                guard let mesh = grid.mesh(forTileZoom: tile.z, atLeast: cells) else { continue }
                if (relief != nil) != selectedRelief {
                    selectedRelief = relief != nil
                    encoder.setRenderPipelineState(selectedRelief ? pipeline.flatReliefPipelineState : pipeline.flatPipelineState)
                }
                if let relief, let groundReliefStore {
                    var uniform = GroundReliefUniform(relief: relief,
                                                      worldUnitsPerMetre: groundReliefStore.worldUnitsPerMetre(over: tile,
                                                                                                               renderMapSize: flatRenderState.renderMapSize),
                                                      datumMetres: groundReliefStore.datumMetres)
                    encoder.setVertexTexture(relief.texture, index: 0)
                    encoder.setVertexBytes(&uniform, length: MemoryLayout<GroundReliefUniform>.stride, index: 9)
                }
                let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.x,
                                                                                 y: tile.y,
                                                                                 z: tile.z,
                                                                                 worldWrap: placement.worldWrap,
                                                                                 flatRenderPan: flatRenderState.pan,
                                                                                 renderMapSize: flatRenderState.renderMapSize)
                let scale = originAndSize.z / 4096.0
                var modelMatrix = Matrix.translationMatrix(x: originAndSize.x,
                                                           y: originAndSize.y,
                                                           z: 0) * Matrix.scaleMatrix(sx: scale, sy: scale, sz: 1)
                encoder.setVertexBytes(&modelMatrix, length: MemoryLayout<matrix_float4x4>.stride, index: 3)
                draw(mesh: mesh, encoder: encoder)
            }
        }
        endDraws(encoder: encoder)
        encoder.popDebugGroup()
    }

    private func encodeSphere(encoder: MTLRenderCommandEncoder,
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
        // The sphere has one copy of the world, and a tile draws whole at
        // its own place whatever slot it stands in: once per source.
        for source in sources {
            guard let texture = source.texture else { continue }
            let tile = source.metalTile.tile
            guard let mesh = grid.mesh(forTileZoom: tile.z) else { continue }
            var surfaceTile = GlobeSurfaceTileUniform(tile: tile)
            encoder.setVertexBytes(&surfaceTile, length: MemoryLayout<GlobeSurfaceTileUniform>.stride, index: 9)
            // The sphere's tile-priority mark (TileSourceStencilPriority).
            encoder.setStencilReferenceValue(TileSourceStencilPriority.reference(sourceZoom: tile.z))
            encoder.setFragmentTexture(texture, index: 0)
            draw(mesh: mesh, encoder: encoder)
        }
        endDraws(encoder: encoder)
        encoder.popDebugGroup()
    }

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

    private func draw(mesh: RasterTileGrid.Mesh, encoder: MTLRenderCommandEncoder) {
        encoder.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
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
