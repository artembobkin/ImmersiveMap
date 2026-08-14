// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

class TileAtlasTexture {
    private struct TileOverviewFadeUniform {
        var overviewAlpha: Float
        var roadAlpha: Float
        var landuseAlpha: Float
        /// Converts point-locked line widths into raster units. The atlas
        /// rasterizes in atlas texels, and the placement sizes a slot to the
        /// tile's device-pixel screen footprint, so a texel approximates a
        /// device pixel and the same conversion holds.
        var pixelsPerPoint: Float
    }

    private struct LineDashUniform {
        var unitsPerPoint: Float
    }

    struct TileData {
        let position: simd_int1
        let textureSize: simd_int1
        let cellSize: simd_int1
        let tile: simd_int3
        let sourceTile: simd_int3
    }

    struct Page {
        let texture: MTLTexture
        var tileData: [TileData]
    }

    let size: Int = 4096
    /// Page mip levels (0..6): without prefiltering, distant slots shimmer.
    /// Depth down to 64:1 is needed for large slots (2048 px) that stretch all
    /// the way to the horizon line: their last rows are perspective-compressed
    /// 20-60x. Levels deeper than 3 are almost free (+0.5% on top of +33%
    /// memory), and dropping them brings the shimmer back exactly in the strip
    /// bordering the horizon.
    static let pageMipLevelCount = 7
    private(set) var pages: [Page] = []
    var projection: matrix_float4x4
    var previousProjectionCount: Int = 0

    private let metalDevice: MTLDevice
    private let tilePipeline: TilePipeline
    // The tile fragment shader statically references the shadow map; the atlas
    // rasterizes world-agnostic texture content, so it always binds the 1x1
    // fallback with a disabled uniform (validation requires the binding even
    // though the strength guard skips sampling).
    private let shadowFallbackTexture: MTLTexture
    // Page background = the style's backdrop color, not white: at deep mip
    // levels the slot edge can blend in the page background, and a contrasting
    // color produces a flickering light line at tile seams.
    private let pageClearColor: MTLClearColor
    private let depthStencilState: MTLDepthStencilState
    private var renderEncoder: MTLRenderCommandEncoder?
    private var activePageIndex: Int?
    // Depth plays no role in atlas rendering (compare .always, writes disabled),
    // but is needed as an attachment because TilePipeline declares depth32Float.
    // One shared transient texture for all pages instead of 64 MB per page.
    private var sharedDepthTexture: MTLTexture?

    private var previousShiftX: Float? = nil
    private var previousShiftY: Float? = nil
    private var previousScale: Float? = nil
    /// Last state given to `setOverviewFadeAlphas`, rebound per allocation in
    /// `draw` with the slot's own texel-per-pixel width scale folded in.
    private var activeFadeUniform = TileOverviewFadeUniform(overviewAlpha: 1,
                                                            roadAlpha: 1,
                                                            landuseAlpha: 1,
                                                            pixelsPerPoint: 1)
    private var activeLineWidthZoomTaper: Float = 1.0
    /// Per-encode context for the dash anchor (see LineDashNominalScale):
    /// the raw point-to-pixel scale, the drawable height, and the world size
    /// of a native tile, from which each allocation derives its own scale.
    private var activeDashPixelsPerPoint: Float = 1.0
    private var activeDrawableHeightPx: Float = 0.0
    private var activeNativeTileWorldSize: Float = 0.0
    
    init(metalDevice: MTLDevice,
         tilePipeline: TilePipeline,
         shadowFallbackTexture: MTLTexture,
         mapBaseColors: ImmersiveMapBaseColors) {
        self.metalDevice = metalDevice
        self.tilePipeline = tilePipeline
        self.shadowFallbackTexture = shadowFallbackTexture
        let backgroundColor = mapBaseColors.getTileBgColor()
        self.pageClearColor = MTLClearColor(red: Double(backgroundColor.x),
                                            green: Double(backgroundColor.y),
                                            blue: Double(backgroundColor.z),
                                            alpha: 1.0)
        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.depthCompareFunction = .always
        depthStateDescriptor.isDepthWriteEnabled = false
        self.depthStencilState = metalDevice.makeDepthStencilState(descriptor: depthStateDescriptor)!
        
        let count = 4
        projection = Matrix.orthographicMatrix(left: 0, right: Float(4096 * count), bottom: 0, top: Float(4096 * count), near: -1, far: 1)
    }
    
    func resetFrame() {
        for index in pages.indices {
            pages[index].tileData = []
        }
    }

    func releasePages() {
        guard renderEncoder == nil else { return }
        pages = []
        sharedDepthTexture = nil
    }

    func beginPageEncoding(commandBuffer: MTLCommandBuffer, pageIndex: Int) -> Bool {
        guard pageIndex >= 0 else { return false }
        guard renderEncoder == nil else { return false }

        ensurePage(at: pageIndex)
        pages[pageIndex].tileData = []
        previousShiftX = nil
        previousShiftY = nil
        previousScale = nil

        let page = pages[pageIndex]
        guard let depthTexture = ensureSharedDepthTexture() else { return false }
        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = page.texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = pageClearColor
        renderPassDescriptor.depthAttachment.texture = depthTexture
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .dontCare
        renderPassDescriptor.depthAttachment.clearDepth = 1.0

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return false
        }
        self.renderEncoder = renderEncoder
        activePageIndex = pageIndex
        renderEncoder.setDepthStencilState(depthStencilState)
        return true
    }
    
    func selectTilePipeline() {
        tilePipeline.selectPipeline(renderEncoder: renderEncoder!)
        // The placeIn clip is only needed on the flat path: in the atlas the
        // cell area is already bounded by the scissor, so the shader gets a
        // disabled clip.
        var localClipBounds = TileLocalClipMath.disabledBounds
        renderEncoder!.setFragmentBytes(&localClipBounds,
                                        length: MemoryLayout<SIMD4<Float>>.stride,
                                        index: 1)
        // Horizon haze is a screen-space effect; when rasterizing into an atlas
        // slot it must be off, otherwise the texture contents get fogged.
        var horizonFog = HorizonFogUniform.disabled
        renderEncoder!.setFragmentBytes(&horizonFog,
                                        length: MemoryLayout<HorizonFogUniform>.stride,
                                        index: 2)
        // Shadows are a flat-world effect and must not bake into the atlas:
        // disabled uniform + fallback texture (the binding itself is mandatory).
        var shadowUniform = ShadowUniform.disabled
        renderEncoder!.setFragmentBytes(&shadowUniform,
                                        length: MemoryLayout<ShadowUniform>.stride,
                                        index: 3)
        // Replaced per allocation in draw(); bound here so the pipeline's
        // binding is complete before the first draw regardless of order.
        var lineDashUniform = LineDashUniform(unitsPerPoint: 0)
        renderEncoder!.setFragmentBytes(&lineDashUniform,
                                        length: MemoryLayout<LineDashUniform>.stride,
                                        index: 4)
        renderEncoder!.setFragmentTexture(shadowFallbackTexture, index: 0)
    }
    
    func endEncoding() {
        renderEncoder?.endEncoding()
        renderEncoder = nil
        activePageIndex = nil
    }

    func setOverviewFadeAlphas(overviewAlpha: Float,
                               roadAlpha: Float,
                               landuseAlpha: Float,
                               pixelsPerPoint: Float,
                               lineWidthZoomTaper: Float = 1.0,
                               drawableHeightPx: Float = 0.0,
                               nativeTileWorldSize: Float = 0.0) {
        guard let renderEncoder else { return }
        // Kept for the per-allocation rebind in draw(): each slot converts
        // point-locked line widths through its own texel-per-pixel ratio,
        // with the low-zoom taper folded into that quantized ratio.
        activeLineWidthZoomTaper = lineWidthZoomTaper
        activeDashPixelsPerPoint = pixelsPerPoint
        activeDrawableHeightPx = drawableHeightPx
        activeNativeTileWorldSize = nativeTileWorldSize
        activeFadeUniform = TileOverviewFadeUniform(overviewAlpha: overviewAlpha,
                                                    roadAlpha: roadAlpha,
                                                    landuseAlpha: landuseAlpha,
                                                    pixelsPerPoint: pixelsPerPoint)
        var uniform = activeFadeUniform
        renderEncoder.setFragmentBytes(&uniform,
                                       length: MemoryLayout<TileOverviewFadeUniform>.stride,
                                       index: 0)
    }
    
    func draw(allocation: TileAtlasAllocation) -> Bool {
        let placeTile = allocation.placeTile
        let placedPos = allocation.placedPosition
        let atlasDepth = allocation.atlasDepth.rawValue
        guard let renderEncoder,
              activePageIndex == allocation.pageIndex,
              pages.indices.contains(allocation.pageIndex) else {
            return false
        }
        
        let placeIn = placeTile.placeIn
        let metalTile = placeTile.metalTile
        let count = 1 << atlasDepth
        if count != previousProjectionCount {
            projection = Matrix.orthographicMatrix(left: 0, right: Float(4096 * count), bottom: 0, top: Float(4096 * count), near: -1, far: 1)
            previousProjectionCount = count
        }
        
        // Add tile metadata for globe placement
        let cellSize = size / count
        let freePtr = Int(placedPos.x) + Int(placedPos.y) * count
        pages[allocation.pageIndex].tileData.append(TileData(position: simd_int1(freePtr),
                                                             textureSize: simd_int1(size),
                                                             cellSize: simd_int1(cellSize),
                                                             tile: simd_int3(Int32(placeIn.x), Int32(placeIn.y), Int32(placeIn.z)),
                                                             sourceTile: simd_int3(Int32(metalTile.tile.x),
                                                                                   Int32(metalTile.tile.y),
                                                                                   Int32(metalTile.tile.z))))
        
        
        let x = Int(placedPos.x)
        let y = Int(placedPos.y)
        let shiftMatrix = Matrix.translationMatrix(x: Float(x) * 4096, y: Float(y) * 4096, z: 0)
        var cameraUniform = CameraUniform(matrix: projection * shiftMatrix,
                                          eye: SIMD3<Float>(0, 0, 1),
                                          padding: 0)

        // Place the tile to cover the required area
        // To do that, scale and translate the tile
        let placeInCount = 1 << placeIn.z
        let zDiff = placeIn.z - metalTile.tile.z
        let scale = powf(2.0, Float(zDiff))
        
        let mtCount = 1 << metalTile.tile.z
        let relX = Float(placeIn.x) - (Float(metalTile.tile.x) * scale)
        let relY = Float(placeIn.y) + (Float((mtCount - 1) - metalTile.tile.y) * scale)
        
        let shiftX = -1.0 * Float(relX) * 4096.0
        let shiftY = -1.0 * Float(Float(placeInCount - 1) - relY) * 4096.0
        if shiftX != previousShiftX || shiftY != previousShiftY || scale != previousScale {
            var modelMatrix = Matrix.translationMatrix(x: shiftX, y: shiftY, z: 0) * Matrix.scaleMatrix(sx: scale, sy: scale, sz: 1)
            renderEncoder.setVertexBytes(&modelMatrix, length: MemoryLayout<matrix_float4x4>.stride, index: 3)
            previousShiftX = shiftX
            previousShiftY = shiftY
            previousScale = scale
        }
        
        
        // Draw the tile into the atlas texture (map texture)
        // Set the drawable area
        let scissorRect = MTLScissorRect(
            x: Int(placedPos.x) * cellSize,
            y: ((count - 1) - Int(placedPos.y)) * cellSize,
            width: cellSize,
            height: cellSize
        )
        renderEncoder.setScissorRect(scissorRect)
        renderEncoder.setVertexBytes(&cameraUniform, length: MemoryLayout<CameraUniform>.stride, index: 1)
        
        // Set tile data for rendering
        let buffers = metalTile.tileBuffers
        // Empty ground: the slot is already cleared to the page background and
        // the placement metadata was added above - nothing to draw, but the
        // placement did happen.
        guard buffers.ground.indicesCount > 0,
              let groundIndices = buffers.ground.indices,
              let groundVertices = buffers.ground.vertices,
              let groundStyles = buffers.ground.styles,
              let groundOverviewMask = buffers.ground.overviewStyleMask,
              let groundLineStyles = buffers.ground.lineStyles else {
            return true
        }
        renderEncoder.setVertexBuffer(groundVertices.buffer, offset: groundVertices.offset, index: 0)
        renderEncoder.setVertexBuffer(groundStyles.buffer, offset: groundStyles.offset, index: 2)
        renderEncoder.setVertexBuffer(groundOverviewMask.buffer, offset: groundOverviewMask.offset, index: 4)
        renderEncoder.setVertexBuffer(groundLineStyles.buffer, offset: groundLineStyles.offset, index: 5)

        // The bake rasterizes in atlas texels while the point-locked widths
        // are stated for screen pixels, and the two drift apart as the
        // fractional-zoom dolly magnifies the page: fold the slot's own
        // texel-per-pixel ratio into the conversion so the width lands right
        // for the scale this slot is actually shown at. The ratio also sits
        // in the atlas redraw hash, which is what re-bakes the page when the
        // dolly moves it a step.
        let coarseTileLineScale = TileAtlasAllocation.coarseTileLineScale(
            sourceTileZoom: metalTile.tile.z
        )
        var fadeUniform = activeFadeUniform
        fadeUniform.pixelsPerPoint *= TileAtlasAllocation.lineWidthRasterScale(
            cellSizePx: allocation.cellSizePx,
            screenDemandPx: allocation.candidate.screenDemandPx,
            zoomTaper: activeLineWidthZoomTaper * coarseTileLineScale
        )
        renderEncoder.setFragmentBytes(&fadeUniform,
                                       length: MemoryLayout<TileOverviewFadeUniform>.stride,
                                       index: 0)

        // Dash anchor: a substitute spans more world than the tile it stands
        // in for, by one factor of two per missing level, so its units get
        // proportionally fewer per pixel and its dashes keep the same size on
        // screen. Camera-independent by design (see LineDashNominalScale);
        // the coarse-tile dash scale compensates the sphere magnification of
        // z0-z2 tiles, floored so dashes stay long instead of turning into
        // stubs at z0.
        let sourceTileWorldSize = activeNativeTileWorldSize
            * powf(2.0, Float(placeIn.z - metalTile.tile.z))
        let coarseTileDashScale = TileAtlasAllocation.coarseTileDashScale(
            sourceTileZoom: metalTile.tile.z
        )
        var lineDashUniform = LineDashUniform(
            unitsPerPoint: coarseTileDashScale * activeDashPixelsPerPoint * LineDashNominalScale.unitsPerPixel(
                sourceTileWorldSize: sourceTileWorldSize,
                drawableHeightPx: activeDrawableHeightPx
            )
        )
        renderEncoder.setFragmentBytes(&lineDashUniform,
                                       length: MemoryLayout<LineDashUniform>.stride,
                                       index: 4)

        renderEncoder.drawIndexedPrimitives(type: .triangle,
                                            indexCount: groundIndices.count,
                                            indexType: buffers.ground.indexType,
                                            indexBuffer: groundIndices.buffer,
                                            indexBufferOffset: groundIndices.offset)

        return true
    }

    private func ensurePage(at pageIndex: Int) {
        while pages.count <= pageIndex {
            pages.append(makePage())
        }
    }

    /// Regenerates mip levels of the redrawn pages; called after the page
    /// render passes finish, in the same command buffer.
    func generateMipmaps(commandBuffer: MTLCommandBuffer, pageIndexes: [Int]) {
        guard renderEncoder == nil else { return }
        let mippedPageIndexes = pageIndexes.filter {
            pages.indices.contains($0) && pages[$0].texture.mipmapLevelCount > 1
        }
        guard mippedPageIndexes.isEmpty == false,
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            return
        }

        for pageIndex in mippedPageIndexes {
            blitEncoder.generateMipmaps(for: pages[pageIndex].texture)
        }
        blitEncoder.endEncoding()
    }

    private func makePage() -> Page {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2D
        descriptor.width = size
        descriptor.height = size
        descriptor.pixelFormat = .bgra8Unorm
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        descriptor.mipmapLevelCount = Self.pageMipLevelCount

        let texture = metalDevice.makeTexture(descriptor: descriptor)!
        texture.label = "TileAtlasPage\(pages.count)"
        return Page(texture: texture,
                    tileData: [])
    }

    private func ensureSharedDepthTexture() -> MTLTexture? {
        if let sharedDepthTexture {
            return sharedDepthTexture
        }

        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                                       width: size,
                                                                       height: size,
                                                                       mipmapped: false)
        depthDescriptor.usage = [.renderTarget]
        // Memoryless: the atlas depth lives only within the page render pass
        // (clear in, dontCare out). Apple-family GPUs keep it in tile memory;
        // Intel Macs fail the family check and the simulator lacks support.
        #if targetEnvironment(simulator)
        depthDescriptor.storageMode = .private
        #else
        depthDescriptor.storageMode = metalDevice.supportsFamily(.apple1) ? .memoryless : .private
        #endif
        let texture = metalDevice.makeTexture(descriptor: depthDescriptor)
        texture?.label = "TileAtlasTextureSharedDepth"
        sharedDepthTexture = texture
        return texture
    }
}
