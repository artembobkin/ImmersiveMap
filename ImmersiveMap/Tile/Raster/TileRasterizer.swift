// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// Renders one tile's picture: the flat ground drawer (`FlatMapSurfaceDrawer`)
/// run over the tile alone, through a camera looking straight down at the
/// tile's extent, into a square texture of the rule's resolution
/// (`FlatRingRule.rasterResolution`). The picture is what the vector
/// draw would paint at the camera zoom where the tile spans that many
/// pixels, so the fades and the point-locked widths read as at that zoom.
/// Each picture takes its own command buffer on the frame's queue, ahead
/// of the frame's own, so the world pass samples it finished.
///
/// Rendered from `FlatMapSurfaceRenderSubsystem.prepareGPU`, one per
/// missing (tile, resolution) of the frame's rasterized targets, and kept
/// by `TileRasterStore`.
final class TileRasterizer {
    /// A tile spans about this many points on screen at its own zoom, so
    /// a picture of `resolution` texels at `pixelsPerPoint` is the map at
    /// zoom `z + log2(resolution / (pointsPerTile * pixelsPerPoint))`.
    static let pointsPerTile: Double = 512

    private let metalContext: RenderMetalContext
    private let tilePipeline: TilePipeline
    private let groundOwnerState: MTLDepthStencilState
    private let tileStencilTestState: MTLDepthStencilState
    private let groundOutlineState: MTLDepthStencilState
    private let groundShadowMaskFallbackTexture: MTLTexture
    /// The depth-stencil (and, under MSAA, the colour) scratch per
    /// resolution: allocated on first use, reused by every picture of
    /// that size.
    private var scratch: [Int: Scratch] = [:]

    private struct Scratch {
        let depthStencil: MTLTexture
        let multisampleColor: MTLTexture?
    }

    init(metalContext: RenderMetalContext,
         tilePipeline: TilePipeline,
         groundOwnerState: MTLDepthStencilState,
         tileStencilTestState: MTLDepthStencilState,
         groundOutlineState: MTLDepthStencilState,
         groundShadowMaskFallbackTexture: MTLTexture) {
        self.metalContext = metalContext
        self.tilePipeline = tilePipeline
        self.groundOwnerState = groundOwnerState
        self.tileStencilTestState = tileStencilTestState
        self.groundOutlineState = groundOutlineState
        self.groundShadowMaskFallbackTexture = groundShadowMaskFallbackTexture
    }

    /// The camera zoom a picture of `resolution` texels a side stands for
    /// (see `pointsPerTile`).
    static func cameraZoom(tileZoom: Int, resolution: Int, pixelsPerPoint: Double) -> Double {
        Double(tileZoom) + log2(Double(resolution) / (pointsPerTile * max(pixelsPerPoint, 0.01)))
    }

    /// The flat render state the picture is drawn in: no pan, and a world
    /// in which the tile is 4096 units wide, one per tile unit, so the
    /// ground drawer's model matrix is the identity up to the tile's
    /// origin.
    static func flatRenderState(tileZoom: Int) -> FlatRenderState {
        FlatRenderState(pan: .zero, renderMapSize: 4096 * Double(1 << tileZoom))
    }

    /// The projection that maps the tile's world square onto the whole
    /// texture, north at the top: a camera straight above the tile, x to
    /// the right, y up, depth in the plane's z ignored (the ground's own
    /// depth is the rank band, see Tile.metal).
    static func projection(tileOrigin: SIMD2<Float>, tileSize: Float) -> matrix_float4x4 {
        let scale = 2 / tileSize
        let translation = SIMD2<Float>(-1 - tileOrigin.x * scale, -1 - tileOrigin.y * scale)
        return matrix_float4x4(columns: (SIMD4<Float>(scale, 0, 0, 0),
                                         SIMD4<Float>(0, scale, 0, 0),
                                         SIMD4<Float>(0, 0, 1, 0),
                                         SIMD4<Float>(translation.x, translation.y, 0, 1)))
    }

    /// Renders the tile's picture at `resolution` texels a side, or nil
    /// when the device declines a texture or a command buffer.
    func render(metalTile: MetalTile,
                resolution: Int,
                pixelsPerPoint: Double,
                clearColor: MTLClearColor) -> MTLTexture? {
        let device = metalContext.device
        let tile = metalTile.tile
        guard let picture = Self.makePictureTexture(device: device, resolution: resolution),
              let scratch = scratch(resolution: resolution, device: device),
              let commandBuffer = metalContext.makeCommandBuffer() else {
            return nil
        }
        commandBuffer.label = "TileRasterizer z\(tile.z)/\(tile.x)/\(tile.y)@\(resolution)"
        let pass = MTLRenderPassDescriptor()
        if let multisampleColor = scratch.multisampleColor {
            pass.colorAttachments[0].texture = multisampleColor
            pass.colorAttachments[0].resolveTexture = picture
            pass.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            pass.colorAttachments[0].texture = picture
            pass.colorAttachments[0].storeAction = .store
        }
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = clearColor
        pass.depthAttachment.texture = scratch.depthStencil
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        pass.stencilAttachment.texture = scratch.depthStencil
        pass.stencilAttachment.loadAction = .clear
        pass.stencilAttachment.clearStencil = 0
        pass.stencilAttachment.storeAction = .dontCare
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return nil
        }
        encoder.label = "TileRasterizer"

        let flatRenderState = Self.flatRenderState(tileZoom: tile.z)
        let originAndSize = ImmersiveMapProjection.flatTileOriginAndSize(x: tile.x,
                                                                         y: tile.y,
                                                                         z: tile.z,
                                                                         worldWrap: 0,
                                                                         flatRenderPan: flatRenderState.pan,
                                                                         renderMapSize: flatRenderState.renderMapSize)
        let projection = Self.projection(tileOrigin: SIMD2<Float>(originAndSize.x, originAndSize.y),
                                         tileSize: originAndSize.z)
        let eye = SIMD3<Float>(originAndSize.x + originAndSize.z / 2,
                               originAndSize.y + originAndSize.z / 2,
                               originAndSize.z)
        let cameraUniform = CameraUniform(matrix: projection, eye: eye, padding: 0)
        let placement = PlaceTile(metalTile: metalTile,
                                  placeIn: VisibleTile(x: tile.x, y: tile.y, z: tile.z, worldWrap: 0))
        // Unlit: the world pass lights the picture through the ground
        // shadow mask when it draws it.
        let shadowMask = GroundShadowMaskBinding(uniform: .disabled, texture: groundShadowMaskFallbackTexture)
        FlatMapSurfaceDrawer.draw(renderEncoder: encoder,
                                  cameraUniform: cameraUniform,
                                  cameraZoom: Self.cameraZoom(tileZoom: tile.z, resolution: resolution, pixelsPerPoint: pixelsPerPoint),
                                  pixelsPerPoint: Float(pixelsPerPoint),
                                  drawableSizePx: SIMD2<Float>(Float(resolution), Float(resolution)),
                                  placeTilesContext: PlaceTilesContext(tilePlacements: [placement]),
                                  flatRenderState: flatRenderState,
                                  groundShadowMask: shadowMask,
                                  tilePipeline: tilePipeline,
                                  groundOwnerState: groundOwnerState,
                                  tileStencilTestState: tileStencilTestState,
                                  groundOutlineState: groundOutlineState,
                                  isWireframeEnabled: false,
                                  // Straight down, w is one everywhere: the vertex
                                  // band is exact and no triangle meets the near plane.
                                  exactRankDepthBelowZoom: 0)
        encoder.endEncoding()
        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: picture)
            blit.endEncoding()
        }
        commandBuffer.commit()
        return picture
    }

    private static func makePictureTexture(device: MTLDevice, resolution: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: resolution,
                                                                  height: resolution,
                                                                  mipmapped: true)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)
        texture?.label = "TileRaster \(resolution)"
        return texture
    }

    private func scratch(resolution: Int, device: MTLDevice) -> Scratch? {
        if let existing = scratch[resolution] {
            return existing
        }
        let sampleCount = metalContext.renderSampleCount
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float_stencil8,
                                                                       width: resolution,
                                                                       height: resolution,
                                                                       mipmapped: false)
        depthDescriptor.usage = .renderTarget
        depthDescriptor.storageMode = .private
        if sampleCount > 1 {
            depthDescriptor.textureType = .type2DMultisample
            depthDescriptor.sampleCount = sampleCount
        }
        guard let depthStencil = device.makeTexture(descriptor: depthDescriptor) else { return nil }
        depthStencil.label = "TileRaster depth \(resolution)"
        var multisampleColor: MTLTexture?
        if sampleCount > 1 {
            let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                           width: resolution,
                                                                           height: resolution,
                                                                           mipmapped: false)
            colorDescriptor.textureType = .type2DMultisample
            colorDescriptor.sampleCount = sampleCount
            colorDescriptor.usage = .renderTarget
            colorDescriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: colorDescriptor) else { return nil }
            texture.label = "TileRaster msaa \(resolution)"
            multisampleColor = texture
        }
        let made = Scratch(depthStencil: depthStencil, multisampleColor: multisampleColor)
        scratch[resolution] = made
        return made
    }

    func releaseScratch() {
        scratch.removeAll()
    }
}
