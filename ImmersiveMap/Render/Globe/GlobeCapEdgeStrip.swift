// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import simd

/// The colour of the tiles' polar edge, baked for the caps: one texel row
/// per pole, a full turn of longitude wide (`GlobeCapStripSampler.width`),
/// holding what the tile geometry shows in its last rows before the
/// Mercator edge. The caps continue that row over the pole (Globe.metal,
/// `globeCapFragmentShader`) and fade it into its own windowed mean, read
/// from the strip's mips. The tiles themselves are drawn on the sphere as
/// geometry; only this sliver is rasterized, because a cap fragment has no
/// tile geometry under it to read.
///
/// One bake draws the ground layer of every placement whose slot touches the
/// pole through the flat tile pipeline, with a model matrix that lays the
/// source tile's polar band across the strip (`modelMatrix(source:pole:)`);
/// everything outside the band leaves the viewport and the placeIn clip
/// distances keep a substitute inside its slot, as on the flat map. The strip
/// is cleared to the map colour first, so a slot whose tile has not arrived
/// continues the placeholder under it.
final class GlobeCapEdgeStrip {
    let northTexture: MTLTexture
    let southTexture: MTLTexture

    private let metalDevice: MTLDevice
    private let pipeline: TilePipeline
    private let shadowFallbackTexture: MTLTexture
    private let depthTexture: MTLTexture
    private let depthState: MTLDepthStencilState
    private let projection: matrix_float4x4

    /// - Parameters:
    ///   - pipeline: the single-sample flat tile pipeline (the same one the
    ///     atlas pages were baked with), whose fragment stage statically
    ///     samples the shadow cascades: they are bound disabled.
    ///   - depthState: depth test off, no writes.
    init(metalDevice: MTLDevice,
         pipeline: TilePipeline,
         shadowFallbackTexture: MTLTexture,
         depthState: MTLDepthStencilState) {
        self.metalDevice = metalDevice
        self.pipeline = pipeline
        self.shadowFallbackTexture = shadowFallbackTexture
        self.depthState = depthState
        northTexture = Self.makeStripTexture(metalDevice: metalDevice, label: "GlobeCapEdgeStripNorth")
        southTexture = Self.makeStripTexture(metalDevice: metalDevice, label: "GlobeCapEdgeStripSouth")
        depthTexture = Self.makeDepthTexture(metalDevice: metalDevice)
        // Strip x is a turn of longitude in tile units, y the polar band
        // mapped to 0..1 (see modelMatrix); near/far bracket the plane.
        projection = Matrix.orthographicMatrix(left: 0,
                                               right: Float(GlobeCapStripSampler.width),
                                               bottom: 0,
                                               top: 1,
                                               near: -1,
                                               far: 1)
    }

    func texture(for pole: GlobeCapPole) -> MTLTexture {
        switch pole {
        case .north: return northTexture
        case .south: return southTexture
        }
    }

    /// The transform from a source tile's render-space units to the strip:
    /// x runs through the whole turn of longitude at the tile's zoom, y maps
    /// the tile's polar band (the last `bandUnits` rows at the pole edge;
    /// render space has y up, so the north edge is at 4096) onto 0..1.
    static func modelMatrix(source: Tile, pole: GlobeCapPole) -> matrix_float4x4 {
        let band = GlobeCapStripSampler.bandUnits
        let extent: Float = 4096
        let bandStart: Float = pole == .north ? extent - band : 0
        let scale = Matrix.scaleMatrix(sx: 1 / Float(1 << source.z), sy: 1 / band, sz: 1)
        let translation = Matrix.translationMatrix(x: Float(source.x) * extent, y: -bandStart, z: 0)
        return scale * translation
    }

    /// Per-bake inputs that are the same for every tile of the strip.
    struct BakeParameters {
        var clearColor: SIMD4<Float>
        var overviewFade: TileOverviewFadeUniform
        var streetPaletteBlend: Float
        /// Pixels per point the dash anchor is stated in (the screen's).
        var dashPixelsPerPoint: Float
        var drawableHeightPx: Float
        /// The flat render map size the dash anchor is derived from.
        var renderMapSize: Double
    }

    /// Bakes one cap's strip from the placements whose slot touches that
    /// pole. Encodes a render pass and the mip generation on `commandBuffer`;
    /// the caller decides when a bake is due (see `GlobeCapRenderSubsystem`).
    func bake(pole: GlobeCapPole,
              placements: [PlaceTile],
              parameters: BakeParameters,
              commandBuffer: MTLCommandBuffer) {
        let texture = texture(for: pole)
        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = texture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: Double(parameters.clearColor.x),
                                                                      green: Double(parameters.clearColor.y),
                                                                      blue: Double(parameters.clearColor.z),
                                                                      alpha: 1)
        passDescriptor.depthAttachment.texture = depthTexture
        passDescriptor.depthAttachment.loadAction = .clear
        passDescriptor.depthAttachment.storeAction = .dontCare
        passDescriptor.depthAttachment.clearDepth = 1
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return
        }
        encoder.label = pole == .north ? "GlobeCapEdgeStrip.north" : "GlobeCapEdgeStrip.south"
        encoder.setDepthStencilState(depthState)
        encoder.setCullMode(.none)
        pipeline.selectPipeline(renderEncoder: encoder)

        var cameraUniform = CameraUniform(matrix: projection, eye: SIMD3<Float>(0, 0, 1), padding: 0)
        var streetPalette = StreetPaletteUniform(blend: parameters.streetPaletteBlend)
        var overviewFade = parameters.overviewFade
        // No haze and no shadow in a strip: both are effects of the view,
        // and the fragment stage's cascade binding is mandatory even disabled.
        var horizonFog = HorizonFogUniform.disabled
        var shadow = ShadowUniform.disabled
        encoder.setVertexBytes(&cameraUniform, length: MemoryLayout<CameraUniform>.stride, index: 1)
        encoder.setVertexBytes(&streetPalette, length: MemoryLayout<StreetPaletteUniform>.stride, index: 6)
        encoder.setFragmentBytes(&overviewFade, length: MemoryLayout<TileOverviewFadeUniform>.stride, index: 0)
        encoder.setFragmentBytes(&horizonFog, length: MemoryLayout<HorizonFogUniform>.stride, index: 2)
        encoder.setFragmentBytes(&shadow, length: MemoryLayout<ShadowUniform>.stride, index: 3)
        encoder.setFragmentTexture(shadowFallbackTexture, index: 0)

        for placement in placements where GlobeCapStripSampler.isPoleRow(placement.placeIn.tile, pole: pole) {
            let metalTile = placement.metalTile
            let buffers = metalTile.tileBuffers.ground
            guard buffers.indicesCount > 0,
                  let indices = buffers.indices,
                  let vertices = buffers.vertices,
                  let styles = buffers.styles,
                  let overviewStyleMask = buffers.overviewStyleMask,
                  let lineStyles = buffers.lineStyles else { continue }

            let tile = metalTile.tile
            var modelMatrix = Self.modelMatrix(source: tile, pole: pole)
            var localClipBounds = TileLocalClipMath.clipBounds(source: tile, placeIn: placement.placeIn.tile)
            let sourceTileWorldSize = Float(parameters.renderMapSize / Double(1 << tile.z))
            var lineDash = LineDashUniform(
                unitsPerPoint: GlobeLineDashScale.coarseTileDashScale(sourceTileZoom: tile.z)
                    * parameters.dashPixelsPerPoint
                    * LineDashNominalScale.unitsPerPixel(sourceTileWorldSize: sourceTileWorldSize,
                                                         drawableHeightPx: parameters.drawableHeightPx)
            )
            encoder.setVertexBuffer(vertices.buffer, offset: vertices.offset, index: 0)
            encoder.setVertexBuffer(styles.buffer, offset: styles.offset, index: 2)
            encoder.setVertexBytes(&modelMatrix, length: MemoryLayout<matrix_float4x4>.stride, index: 3)
            encoder.setVertexBuffer(overviewStyleMask.buffer, offset: overviewStyleMask.offset, index: 4)
            encoder.setVertexBuffer(lineStyles.buffer, offset: lineStyles.offset, index: 5)
            encoder.setVertexBytes(&localClipBounds, length: MemoryLayout<SIMD4<Float>>.stride, index: 7)
            encoder.setFragmentBytes(&lineDash, length: MemoryLayout<LineDashUniform>.stride, index: 4)
            encoder.drawIndexedPrimitives(type: .triangle,
                                          indexCount: indices.count,
                                          indexType: buffers.indexType,
                                          indexBuffer: indices.buffer,
                                          indexBufferOffset: indices.offset)
        }
        encoder.endEncoding()

        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.label = "GlobeCapEdgeStrip.mips"
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
        }
    }

    private static func makeStripTexture(metalDevice: MTLDevice, label: String) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: GlobeCapStripSampler.width,
                                                                  height: 1,
                                                                  mipmapped: true)
        descriptor.mipmapLevelCount = GlobeCapStripSampler.mipLevelCount
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        let texture = metalDevice.makeTexture(descriptor: descriptor)!
        texture.label = label
        return texture
    }

    private static func makeDepthTexture(metalDevice: MTLDevice) -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                                  width: GlobeCapStripSampler.width,
                                                                  height: 1,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget]
        // Lives only within the bake pass (clear in, dontCare out); the
        // pipeline declares a depth attachment, so one has to be there.
        #if targetEnvironment(simulator)
        descriptor.storageMode = .private
        #else
        descriptor.storageMode = metalDevice.supportsFamily(.apple1) ? .memoryless : .private
        #endif
        let texture = metalDevice.makeTexture(descriptor: descriptor)!
        texture.label = "GlobeCapEdgeStripDepth"
        return texture
    }
}
