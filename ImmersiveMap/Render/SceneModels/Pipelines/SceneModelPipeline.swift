// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

/// One opaque world-pass pipeline for every scene model: textured and
/// constant-color submeshes share it, untextured ones bind `whiteTexture`.
class SceneModelPipeline {
    let pipelineState: MTLRenderPipelineState
    /// Depth-only replay into the shadow map: no color attachments and no
    /// fragment function, the rasterizer writes bare depth.
    let shadowPipelineState: MTLRenderPipelineState
    let baseColorSampler: MTLSamplerState
    let whiteTexture: MTLTexture

    init(metalDevice: MTLDevice,
         layer: CAMetalLayer,
         library: MTLLibrary,
         sampleCount: Int = 1) {
        let vertexFunction = library.makeFunction(name: "sceneModelVertexShader")
        let fragmentFunction = library.makeFunction(name: "sceneModelFragmentShader")

        // The canonical interleaved layout produced by SceneModelAssetLoader.
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float3
        vertexDescriptor.attributes[1].offset = SceneModelAssetLoader.normalOffset
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.attributes[2].format = .float2
        vertexDescriptor.attributes[2].offset = SceneModelAssetLoader.uvOffset
        vertexDescriptor.attributes[2].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = SceneModelAssetLoader.vertexStride
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.rasterSampleCount = sampleCount
        pipelineDescriptor.colorAttachments[0].pixelFormat = layer.pixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

        self.pipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)

        let shadowDescriptor = MTLRenderPipelineDescriptor()
        shadowDescriptor.vertexFunction = library.makeFunction(name: "sceneModelShadowVertexShader")
        shadowDescriptor.fragmentFunction = nil
        shadowDescriptor.vertexDescriptor = vertexDescriptor
        shadowDescriptor.rasterSampleCount = 1
        shadowDescriptor.depthAttachmentPixelFormat = .depth32Float
        self.shadowPipelineState = try! metalDevice.makeRenderPipelineState(descriptor: shadowDescriptor)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .repeat
        samplerDescriptor.tAddressMode = .repeat
        self.baseColorSampler = metalDevice.makeSamplerState(descriptor: samplerDescriptor)!

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                         width: 1,
                                                                         height: 1,
                                                                         mipmapped: false)
        textureDescriptor.usage = .shaderRead
        let whiteTexture = metalDevice.makeTexture(descriptor: textureDescriptor)!
        var whitePixel: [UInt8] = [255, 255, 255, 255]
        whiteTexture.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                             mipmapLevel: 0,
                             withBytes: &whitePixel,
                             bytesPerRow: 4)
        self.whiteTexture = whiteTexture
    }

    func selectPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(pipelineState)
    }

    func selectShadowPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(shadowPipelineState)
    }
}
