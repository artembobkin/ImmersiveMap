// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

/// One opaque world-pass pipeline for every scene model: textured and
/// constant-color submeshes share it, untextured ones bind `whiteTexture`.
class SceneModelPipeline {
    let pipelineState: MTLRenderPipelineState
    /// Variant for the framebuffer-fetch world pass (Apple GPUs, nil
    /// elsewhere): identical, but declares the pass's second building
    /// attachment with an empty write mask so the pipeline stays
    /// pass-compatible.
    let withBuildingImagePipelineState: MTLRenderPipelineState?
    /// Depth-only replay into the shadow map: no color attachments and no
    /// fragment function, the rasterizer writes bare depth.
    let shadowPipelineState: MTLRenderPipelineState
    /// Depth-only replay into the overlay pass, encoded before the labels so
    /// their far-plane fragments depth-test against the model silhouettes.
    /// The overlay pass keeps its single-sample color attachment bound, so the
    /// pipeline declares the format with all color writes masked off.
    let labelOcclusionPipelineState: MTLRenderPipelineState
    let baseColorSampler: MTLSamplerState
    let whiteTexture: MTLTexture

    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int = 1,
         supportsFramebufferFetch: Bool = false) {
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
        pipelineDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

        self.pipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)

        if supportsFramebufferFetch {
            pipelineDescriptor.colorAttachments[1].pixelFormat = pixelFormat
            pipelineDescriptor.colorAttachments[1].writeMask = []
            self.withBuildingImagePipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } else {
            self.withBuildingImagePipelineState = nil
        }

        let shadowDescriptor = MTLRenderPipelineDescriptor()
        shadowDescriptor.vertexFunction = library.makeFunction(name: "sceneModelShadowVertexShader")
        shadowDescriptor.fragmentFunction = nil
        shadowDescriptor.vertexDescriptor = vertexDescriptor
        shadowDescriptor.rasterSampleCount = 1
        shadowDescriptor.depthAttachmentPixelFormat = ShadowCascadeAtlas.depthPixelFormat
        // Required for layered rendering: the vertex stage routes instances
        // to cascade slices via [[render_target_array_index]].
        shadowDescriptor.inputPrimitiveTopology = .triangle
        self.shadowPipelineState = try! metalDevice.makeRenderPipelineState(descriptor: shadowDescriptor)

        let occlusionDescriptor = MTLRenderPipelineDescriptor()
        occlusionDescriptor.vertexFunction = library.makeFunction(name: "sceneModelDepthOnlyVertexShader")
        occlusionDescriptor.fragmentFunction = nil
        occlusionDescriptor.vertexDescriptor = vertexDescriptor
        occlusionDescriptor.rasterSampleCount = 1
        occlusionDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        occlusionDescriptor.colorAttachments[0].writeMask = []
        occlusionDescriptor.depthAttachmentPixelFormat = .depth32Float
        self.labelOcclusionPipelineState = try! metalDevice.makeRenderPipelineState(descriptor: occlusionDescriptor)

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

    func selectPipeline(renderEncoder: MTLRenderCommandEncoder,
                        withBuildingImageAttachment: Bool = false) {
        if withBuildingImageAttachment, let withBuildingImagePipelineState {
            renderEncoder.setRenderPipelineState(withBuildingImagePipelineState)
            return
        }
        selectMainPipeline(renderEncoder: renderEncoder)
    }

    private func selectMainPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(pipelineState)
    }

    func selectShadowPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(shadowPipelineState)
    }

    func selectLabelOcclusionPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(labelOcclusionPipelineState)
    }
}
