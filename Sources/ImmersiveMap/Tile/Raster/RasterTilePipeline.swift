// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// The pipelines of the raster tiles (TileRaster.metal): the bake, which
/// draws a tile's fills into its window of the frame's atlas when its
/// texture must be drawn again, and the draws of the texture on the plane,
/// on the resting sphere and through the unroll.
final class RasterTilePipeline {
    /// The samples per texel the bake draws with, resolved into the
    /// texture's first level: the edges of the fills are smooth before the
    /// mip chain is made from them.
    static let bakeSampleCount = 4

    let bakePipelineState: MTLRenderPipelineState
    let flatPipelineState: MTLRenderPipelineState
    /// The plane's draw on the ground relief (TileRaster.metal,
    /// kTileRasterRelief): the grid raised by the terrain bound at vertex
    /// texture 0 and buffer 9.
    let flatReliefPipelineState: MTLRenderPipelineState
    let spherePurePipelineState: MTLRenderPipelineState
    let sphereMorphPipelineState: MTLRenderPipelineState
    /// The ground relief as a shadow caster (`GroundReliefShadowCasterSubsystem`):
    /// the grid raised by the terrain, from the light, depth only into the
    /// shadow map, as the buildings' caster pass draws.
    let reliefShadowPipelineState: MTLRenderPipelineState

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
        bake.colorAttachments[0].pixelFormat = RasterTileTexture.pixelFormat
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
        func drawState(label: String, vertex: String, fragment: String, relief: Bool = false) -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = label
            let values = MTLFunctionConstantValues()
            var reliefValue = relief
            values.setConstantValue(&reliefValue, type: .bool, index: 0)
            descriptor.vertexFunction = try! library.makeFunction(name: vertex, constantValues: values)
            // The fragment too: the relief's samples the shadow cascades
            // at its raised point (TileRaster.metal).
            descriptor.fragmentFunction = try! library.makeFunction(name: fragment, constantValues: values)
            descriptor.rasterSampleCount = sampleCount
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            descriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
            descriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
            return try! metalDevice.makeRenderPipelineState(descriptor: descriptor)
        }
        flatPipelineState = drawState(label: "RasterTileFlat",
                                      vertex: "tileRasterFlatVertexShader",
                                      fragment: "tileRasterFlatFragmentShader")
        flatReliefPipelineState = drawState(label: "RasterTileFlatRelief",
                                            vertex: "tileRasterFlatVertexShader",
                                            fragment: "tileRasterFlatFragmentShader",
                                            relief: true)
        spherePurePipelineState = drawState(label: "RasterTileSpherePure",
                                            vertex: "tileRasterSpherePureVertexShader",
                                            fragment: "tileRasterSphereFragmentShader")
        sphereMorphPipelineState = drawState(label: "RasterTileSphereMorph",
                                             vertex: "tileRasterSphereMorphVertexShader",
                                             fragment: "tileRasterSphereFragmentShader")

        let shadow = MTLRenderPipelineDescriptor()
        shadow.label = "RasterTileReliefShadow"
        shadow.vertexFunction = library.makeFunction(name: "tileRasterReliefShadowVertexShader")
        shadow.fragmentFunction = nil
        shadow.rasterSampleCount = 1
        shadow.depthAttachmentPixelFormat = ShadowCascadeAtlas.depthPixelFormat
        // A plain 2D depth attachment, as the buildings' caster pass.
        shadow.inputPrimitiveTopology = .triangle
        reliefShadowPipelineState = try! metalDevice.makeRenderPipelineState(descriptor: shadow)
    }
}
