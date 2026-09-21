// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// The rasterized tile pipelines of the sphere (TileSphereRaster.metal):
/// one grid per pictured source in the spherical world pass, blended by
/// the picture's share of the pixel in the raster zone (`RasterZone`). Two
/// states, like the vector ground's: the resting sphere and the unfurl,
/// which carries the unroll's clip distance.
final class TileSphereRasterPipeline {
    let pureState: MTLRenderPipelineState
    let morphState: MTLRenderPipelineState

    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int = 1) {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.fragmentFunction = library.makeFunction(name: "tileSphereRasterFragmentShader")
        descriptor.rasterSampleCount = sampleCount
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        descriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
        descriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
        descriptor.label = "TileSphereRasterPipeline pure"
        descriptor.vertexFunction = library.makeFunction(name: "tileSphereRasterPureVertexShader")
        pureState = try! metalDevice.makeRenderPipelineState(descriptor: descriptor)
        descriptor.label = "TileSphereRasterPipeline morph"
        descriptor.vertexFunction = library.makeFunction(name: "tileSphereRasterMorphVertexShader")
        morphState = try! metalDevice.makeRenderPipelineState(descriptor: descriptor)
    }

    func selectPipeline(renderEncoder: MTLRenderCommandEncoder, morph: Bool) {
        renderEncoder.setRenderPipelineState(morph ? morphState : pureState)
    }
}
