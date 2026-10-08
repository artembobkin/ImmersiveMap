// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// The pipelines of the raster tiles (TileRaster.metal): the bake, which
/// draws a tile's fills into its texture, and the draws of the texture on
/// the plane, on the resting sphere and through the unroll.
final class RasterTilePipeline {
    /// The samples per texel the bake draws with, resolved into the
    /// texture's first level: the edges of the fills are smooth before the
    /// mip chain is made from them.
    static let bakeSampleCount = 4

    let bakePipelineState: MTLRenderPipelineState
    let flatPipelineState: MTLRenderPipelineState
    let spherePurePipelineState: MTLRenderPipelineState
    let sphereMorphPipelineState: MTLRenderPipelineState

    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int = 1) {
        let bake = MTLRenderPipelineDescriptor()
        bake.label = "RasterTileBake"
        bake.vertexFunction = library.makeFunction(name: "tileRasterBakeVertexShader")
        bake.fragmentFunction = library.makeFunction(name: "tileRasterBakeFragmentShader")
        bake.vertexDescriptor = TilePipeline.makeVertexDescriptor()
        bake.rasterSampleCount = Self.bakeSampleCount
        bake.colorAttachments[0].pixelFormat = RasterTileLayout.pixelFormat
        // The fills in buffer order, each over what is under it, the way
        // the vector ground layers them.
        bake.colorAttachments[0].isBlendingEnabled = true
        bake.colorAttachments[0].rgbBlendOperation = .add
        bake.colorAttachments[0].alphaBlendOperation = .add
        bake.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        bake.colorAttachments[0].sourceAlphaBlendFactor = .one
        bake.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        bake.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        bakePipelineState = try! metalDevice.makeRenderPipelineState(descriptor: bake)

        // The draws: opaque, in the world pass, through the ground's depth
        // and stencil.
        func drawState(label: String, vertex: String, fragment: String) -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = label
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.rasterSampleCount = sampleCount
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            descriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
            descriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
            return try! metalDevice.makeRenderPipelineState(descriptor: descriptor)
        }
        flatPipelineState = drawState(label: "RasterTileFlat",
                                      vertex: "tileRasterFlatVertexShader",
                                      fragment: "tileRasterFlatFragmentShader")
        spherePurePipelineState = drawState(label: "RasterTileSpherePure",
                                            vertex: "tileRasterSpherePureVertexShader",
                                            fragment: "tileRasterSphereFragmentShader")
        sphereMorphPipelineState = drawState(label: "RasterTileSphereMorph",
                                             vertex: "tileRasterSphereMorphVertexShader",
                                             fragment: "tileRasterSphereFragmentShader")
    }
}
