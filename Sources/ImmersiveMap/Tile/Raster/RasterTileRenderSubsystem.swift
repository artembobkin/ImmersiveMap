// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// The ground of the raster targets, the slots of a ring rule with a raster
/// size (`VisibleContentState.rasterTiles`): the vector path with one step
/// between, a texture. The placements are the vector placements
/// (`TilePlacementState.placeTilesContext`), the targets' own tiles and
/// the descendants and ancestors standing in for them, kept and released
/// as every vector tile is. A tile placed in a raster slot has its fills
/// drawn into a texture of the slot's size (`prepareGPU`, before the world
/// pass, the zoom fades at the planning zoom as the vector ground draws
/// them, then the mip chain), and the world pass draws the texture on the
/// tile's grid (`RasterTileGrid`), first in the ground's layer on either
/// surface, before the vector ground. A tile keeps its texture from
/// frame to frame and is drawn into it again only when what the texture
/// shows would change (`Baked`): another tile in the slot (a new load of
/// it), another size, or a fade of one of its styles moved at the
/// planning zoom. A pan or a camera at rest draws no texture at all, and
/// a texture is never stale, never missing while its tile is in, and
/// never a hole where the vector ground would not be one. The tiles drawn
/// again in a frame are drawn in one pass, each in its own window of one
/// shared atlas, and copied from there into their textures with their mip
/// chains in one blit (`prepareGPU`).
///
/// A texture is opaque and owns its pixels as an opaque fill does: it
/// writes a depth half a rank step behind the ground's first, so the
/// lines drawn over it pass and a vector tile drawn over it wins outright
/// (TileRaster.metal), and it paints the ground the planner gave its
/// tile, drawn at full extent under the tile-priority stencil
/// (`TileSourceStencilPriority`) on either surface. On the plane it takes the
/// ground shadow mask as the vector ground does, and rises by the ground
/// relief where the frame is on it (`GroundReliefStore`), on a grid as
/// fine as the zoom's flattening grid but no finer than its terrain and
/// its raster can show (`RasterTileGrid.reliefCells`). On the sphere it follows the
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
        /// What the texture is drawn from this frame (`bakeSignature`),
        /// and whether it must be drawn into again for it.
        var signature: UInt64 = 0
        var needsBake = false
    }

    /// A tile's texture as it was last drawn: by which tile object (kept,
    /// so its identity is never another tile's), at which size, from which
    /// fades (`bakeSignature`), nil until the draw is encoded.
    private struct Baked {
        let metalTile: MetalTile
        let size: Int
        var signature: UInt64?
        let texture: MTLTexture
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
    /// The shadow map the relief's draws sample at their raised points
    /// (`GroundShadowMaskBinding.cascades`), and its depth fallback.
    private let shadowMapTextureProvider: () -> MTLTexture?
    private let shadowFallbackTexture: MTLTexture?
    private let groundReliefStore: GroundReliefStore?
    private let groundFlattening: ImmersiveMapSettings.TileSettings.GroundFlatteningSettings

    /// The frame's sources, by the tile drawn, finest first.
    private var sources: [Source] = []
    /// The textures of the tiles drawn in raster slots, as last drawn.
    private var bakedByTile: [Tile: Baked] = [:]
    /// The textures of the tiles that left the raster slots, by size, for
    /// the next ones: a pan trades a few each frame.
    private var freeTextures: [Int: [MTLTexture]] = [:]
    /// The atlas the frame's draws go through: multisampled (memoryless
    /// where the GPU keeps a pass's samples on chip) and resolved, grown to
    /// the largest frame's need.
    private var bakeAtlas: (samples: MTLTexture, resolved: MTLTexture)?
    /// The textures this frame's pass draws, recorded as drawn once the
    /// frame is committed (`frameCommitted`): a frame dropped after its
    /// encoding never ran its pass, and its tiles draw again.
    private var pendingBakes: [(tile: Tile, texture: MTLTexture, signature: UInt64)] = []

    /// How many free textures a size keeps: the frames of a pan, where the
    /// need moves by a few.
    static let poolSlack = 16
    /// The steps a style's fade is drawn in a texture at: the texture is
    /// drawn again when a fade moves by a step, at most a 64th of its
    /// alpha off between two draws, under anything the eye sees.
    static let fadeSteps: Float = 64

    init(device: MTLDevice,
         pipeline: RasterTilePipeline,
         settings: ImmersiveMapSettings.TileSettings.RasterizationSettings,
         groundOwnerState: MTLDepthStencilState,
         sphereOpaqueOwnerState: MTLDepthStencilState,
         depthDisabledState: MTLDepthStencilState,
         debugOverlayControls: DebugOverlayControlState,
         groundShadowMaskTextureProvider: @escaping () -> MTLTexture?,
         groundShadowMaskFallbackTexture: MTLTexture,
         shadowMapTextureProvider: @escaping () -> MTLTexture? = { nil },
         shadowFallbackTexture: MTLTexture? = nil,
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
        self.shadowMapTextureProvider = shadowMapTextureProvider
        self.shadowFallbackTexture = shadowFallbackTexture
    }

    // MARK: - The frame's sources

    /// The frame's raster placements, grouped by the tile drawn: a tile
    /// placed in several raster slots draws into one texture, of the
    /// largest size among them, and is drawn once per wrap copy it is
    /// placed at, at full extent. The placement prepass has settled which
    /// source a pixel shows (`TileSourceStencilPriority`), and the sources
    /// are ordered finest first for the pipeline's sake alone.
    func update(frameContext: FrameContext) {
        let placements = frameContext.sharedState.tilePlacementState.placeTilesContext.tilePlacements
        sources.removeAll(keepingCapacity: true)
        pendingBakes.removeAll(keepingCapacity: true)
        guard placements.contains(where: { $0.rules.raster != nil }) else {
            keepTextures(of: [])
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
        // Each its texture as last drawn, or one to draw into: its own
        // when it has one of its size, else a free one.
        var fade = TileOverviewFadeUniform(pixelsPerPoint: 1, cameraZoom: Float(frameContext.planningZoom))
        for index in sources.indices {
            let tile = sources[index].metalTile.tile
            let size = sources[index].size
            let signature = Self.bakeSignature(of: sources[index].metalTile.tileBuffers.ground, fade: &fade)
            sources[index].signature = signature
            if let baked = bakedByTile[tile], baked.size == size {
                sources[index].texture = baked.texture
                sources[index].needsBake = baked.metalTile !== sources[index].metalTile || baked.signature != signature
            } else {
                sources[index].texture = freeTexture(size: size)
                sources[index].needsBake = true
            }
        }
        keepTextures(of: sources)
    }

    /// What a tile's texture is drawn from at a zoom: its fill runs' fades,
    /// each in `fadeSteps` steps, the one thing of the draw that moves with
    /// the camera. Equal signatures of one tile draw one texture.
    private static func bakeSignature(of ground: TileBuffers.GeometryLayer, fade: inout TileOverviewFadeUniform) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for run in ground.styleRuns where run.isFillsClass {
            let step = UInt64((TileStyleFadeMath.progress(zoomFade: run.zoomFade, overviewFade: fade) * fadeSteps).rounded())
            hash = (hash ^ step) &* 1_099_511_628_211
        }
        return hash
    }

    /// Keeps the textures of `sources`, recording each as drawn for its
    /// tile (the signature once the draw is encoded), and frees the rest
    /// for the tiles to come, a size's free textures kept to `poolSlack`.
    private func keepTextures(of sources: [Source]) {
        var kept: [Tile: Baked] = [:]
        for source in sources {
            guard let texture = source.texture else { continue }
            let tile = source.metalTile.tile
            let previous = bakedByTile[tile]
            let signature = source.needsBake ? nil : previous?.signature
            kept[tile] = Baked(metalTile: source.metalTile, size: source.size, signature: signature, texture: texture)
        }
        for (tile, baked) in bakedByTile where kept[tile]?.texture !== baked.texture {
            var free = freeTextures[baked.size] ?? []
            if free.count < Self.poolSlack {
                free.append(baked.texture)
            }
            freeTextures[baked.size] = free
        }
        bakedByTile = kept
        // Out of the raster rings, every texture and the atlas go.
        if kept.isEmpty {
            freeTextures.removeAll()
            bakeAtlas = nil
        }
    }

    private func freeTexture(size: Int) -> MTLTexture? {
        if var free = freeTextures[size], let texture = free.popLast() {
            freeTextures[size] = free
            return texture
        }
        return RasterTileTexture.make(device: device, size: size)
    }

    /// The stencil value of a source (`TileSourceStencilPriority`).
    private static func reference(of source: Source) -> UInt32 {
        TileSourceStencilPriority.reference(sourceZoom: source.metalTile.tile.z)
    }


    // MARK: - The textures

    /// Draws the fills of the sources whose texture must be drawn again
    /// this frame (`Source.needsBake`), and only theirs, in one pass on the
    /// frame's command buffer: each in its own window of the atlas, through
    /// the atlas's samples, resolved at the pass's end. Then one blit copies
    /// each window into its tile's texture and makes the texture's mip
    /// chain. The fades are the planning zoom's, as the vector ground draws
    /// them. A frame that draws no texture encodes nothing.
    func prepareGPU(frameContext: FrameContext, resourceRegistry _: RenderResourceRegistry) {
        let drawn = sources.indices.filter { sources[$0].needsBake && sources[$0].texture != nil }
        guard drawn.isEmpty == false, let commandBuffer = frameContext.commandBuffer else { return }
        let cell = drawn.reduce(0) { max($0, sources[$1].size) }
        let columns = Int(Double(drawn.count).squareRoot().rounded(.up))
        let rows = (drawn.count + columns - 1) / columns
        guard let atlas = atlas(width: columns * cell, height: rows * cell) else { return }

        let base = frameContext.services.baseColors.map
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = atlas.samples
        descriptor.colorAttachments[0].resolveTexture = atlas.resolved
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: Double(base.x), green: Double(base.y),
                                                                  blue: Double(base.z), alpha: 1)
        descriptor.colorAttachments[0].storeAction = .multisampleResolve
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = "RasterTiles \(drawn.count)"
        encoder.setRenderPipelineState(pipeline.bakePipelineState)
        encoder.setCullMode(.none)
        var fade = TileOverviewFadeUniform(pixelsPerPoint: 1, cameraZoom: Float(frameContext.planningZoom))
        var windows: [(index: Int, origin: MTLOrigin)] = []
        for (slot, index) in drawn.enumerated() {
            let size = sources[index].size
            let origin = MTLOrigin(x: (slot % columns) * cell, y: (slot / columns) * cell, z: 0)
            // The tile's extent fills its window: the clip volume is the
            // window, so nothing of a tile reaches its neighbour's.
            encoder.setViewport(MTLViewport(originX: Double(origin.x), originY: Double(origin.y),
                                            width: Double(size), height: Double(size), znear: 0, zfar: 1))
            encoder.setScissorRect(MTLScissorRect(x: origin.x, y: origin.y, width: size, height: size))
            Self.encodeFills(of: sources[index].metalTile.tileBuffers.ground, fade: &fade, encoder: encoder)
            windows.append((index, origin))
        }
        encoder.endEncoding()

        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.label = "RasterTileCopies"
        for window in windows {
            guard let texture = sources[window.index].texture else { continue }
            let size = sources[window.index].size
            blit.copy(from: atlas.resolved, sourceSlice: 0, sourceLevel: 0, sourceOrigin: window.origin,
                      sourceSize: MTLSize(width: size, height: size, depth: 1),
                      to: texture, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.generateMipmaps(for: texture)
            pendingBakes.append((sources[window.index].metalTile.tile, texture, sources[window.index].signature))
        }
        blit.endEncoding()
    }

    /// The frame's pass is on the GPU: its textures are drawn, from the
    /// signatures they were drawn from.
    func frameCommitted() {
        for bake in pendingBakes where bakedByTile[bake.tile]?.texture === bake.texture {
            bakedByTile[bake.tile]?.signature = bake.signature
        }
        pendingBakes.removeAll(keepingCapacity: true)
    }

    /// The atlas the frame's draws go through, at least `width` by
    /// `height`, grown when a frame needs more.
    private func atlas(width: Int, height: Int) -> (samples: MTLTexture, resolved: MTLTexture)? {
        if let bakeAtlas, bakeAtlas.resolved.width >= width, bakeAtlas.resolved.height >= height {
            return bakeAtlas
        }
        let side = (width: max(width, bakeAtlas?.resolved.width ?? 0), height: max(height, bakeAtlas?.resolved.height ?? 0))
        let samples = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RasterTileTexture.pixelFormat,
                                                               width: side.width,
                                                               height: side.height,
                                                               mipmapped: false)
        samples.textureType = .type2DMultisample
        samples.sampleCount = RasterTilePipeline.bakeSampleCount
        samples.usage = [.renderTarget]
        samples.storageMode = device.supportsFamily(.apple2) ? .memoryless : .private
        let resolved = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RasterTileTexture.pixelFormat,
                                                                width: side.width,
                                                                height: side.height,
                                                                mipmapped: false)
        resolved.usage = [.renderTarget]
        resolved.storageMode = .private
        guard let samplesTexture = device.makeTexture(descriptor: samples),
              let resolvedTexture = device.makeTexture(descriptor: resolved) else {
            return nil
        }
        samplesTexture.label = "RasterTileAtlasSamples"
        resolvedTexture.label = "RasterTileAtlas"
        bakeAtlas = (samplesTexture, resolvedTexture)
        return bakeAtlas
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

    /// Lets go of every texture kept from earlier frames: the tiles still
    /// in raster slots draw theirs again.
    func handleMemoryWarning() {
        bakedByTile.removeAll()
        freeTextures.removeAll()
        bakeAtlas = nil
    }

    func evict() {
        sources.removeAll()
        bakedByTile.removeAll()
        freeTextures.removeAll()
        bakeAtlas = nil
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
                                                               fallbackTexture: groundShadowMaskFallbackTexture,
                                                               shadowMapTexture: shadowMapTextureProvider(),
                                                               shadowFallbackTexture: shadowFallbackTexture ?? groundShadowMaskFallbackTexture)
        var shadowUniform = groundShadowMask.uniform
        encoder.setFragmentBytes(&shadowUniform, length: MemoryLayout<ShadowUniform>.stride, index: 3)
        encoder.setFragmentTexture(groundShadowMask.texture, index: 1)
        // The relief's variant samples the cascades at its raised points.
        encoder.setFragmentTexture(groundShadowMask.cascades, index: 2)
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
            // the planner's marks (TileSourceStencilPriority).
            encoder.setStencilReferenceValue(Self.reference(of: source))
            for placement in source.placements {
                let relief = groundReliefStore?.relief(for: tile, targetZoom: placement.targetZoom)
                // As fine as the terrain and the raster can show, no finer.
                let cells = relief.map {
                    RasterTileGrid.reliefCells(gridCells: groundFlattening.grid(forTileZoom: tile.z), relief: $0, rasterSize: source.size)
                } ?? 0
                guard let mesh = grid.mesh(forTileZoom: tile.z, atLeast: cells) else { continue }
                if (relief != nil) != selectedRelief {
                    selectedRelief = relief != nil
                    encoder.setRenderPipelineState(selectedRelief ? pipeline.flatReliefPipelineState : pipeline.flatPipelineState)
                }
                if let relief, let groundReliefStore {
                    GroundReliefUniform.bind(relief,
                                             over: tile,
                                             store: groundReliefStore,
                                             renderMapSize: flatRenderState.renderMapSize,
                                             encoder: encoder)
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
            encoder.setStencilReferenceValue(Self.reference(of: source))
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
