// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

/// The world-pass pipelines of the scene models: one opaque pipeline every
/// model draws with (textured and constant-color submeshes share it,
/// untextured ones bind `whiteTexture`), its variant that drops the
/// fragments below the ground and the stencil-only footprint pipeline, the
/// two the ground cut adds (see SceneModel.metal), and the shadow caster
/// pipeline.
class SceneModelPipeline {
    let pipelineState: MTLRenderPipelineState
    /// The opaque pipeline with `kSceneModelClipsBelowGround` on: the second
    /// draw of a model that cuts into the ground, outside its ground hole.
    let belowGroundClippedPipelineState: MTLRenderPipelineState
    /// The model flattened onto the ground plane, writing neither colour
    /// nor depth: the draw that raises or lowers the ground hole bit.
    let groundFootprintPipelineState: MTLRenderPipelineState
    /// Depth-only replay into the shadow map: no color attachments and no
    /// fragment function, the rasterizer writes bare depth.
    let shadowPipelineState: MTLRenderPipelineState
    let baseColorSampler: MTLSamplerState
    let whiteTexture: MTLTexture

    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int = 1) {
        let vertexFunction = library.makeFunction(name: "sceneModelVertexShader")

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

        func makeFragmentFunction(clipsBelowGround: Bool) -> MTLFunction {
            let constants = MTLFunctionConstantValues()
            var clips = clipsBelowGround
            constants.setConstantValue(&clips, type: .bool, index: 0)
            return try! library.makeFunction(name: "sceneModelFragmentShader", constantValues: constants)
        }

        func makeMainDescriptor(clipsBelowGround: Bool) -> MTLRenderPipelineDescriptor {
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = makeFragmentFunction(clipsBelowGround: clipsBelowGround)
            pipelineDescriptor.vertexDescriptor = vertexDescriptor
            pipelineDescriptor.rasterSampleCount = sampleCount
            pipelineDescriptor.colorAttachments[0].pixelFormat = pixelFormat
            pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
            pipelineDescriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
            return pipelineDescriptor
        }

        self.pipelineState = try! metalDevice.makeRenderPipelineState(
            descriptor: makeMainDescriptor(clipsBelowGround: false))
        self.belowGroundClippedPipelineState = try! metalDevice.makeRenderPipelineState(
            descriptor: makeMainDescriptor(clipsBelowGround: true))

        // Stencil only: the colour attachment is the world pass's, masked
        // off, and no fragment function runs. The depth-stencil state of the
        // draw keeps the depth untouched.
        let footprintDescriptor = MTLRenderPipelineDescriptor()
        footprintDescriptor.vertexFunction = library.makeFunction(name: "sceneModelGroundFootprintVertexShader")
        footprintDescriptor.fragmentFunction = nil
        footprintDescriptor.vertexDescriptor = vertexDescriptor
        footprintDescriptor.rasterSampleCount = sampleCount
        footprintDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        footprintDescriptor.colorAttachments[0].writeMask = []
        footprintDescriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
        footprintDescriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
        self.groundFootprintPipelineState = try! metalDevice.makeRenderPipelineState(descriptor: footprintDescriptor)

        let shadowDescriptor = MTLRenderPipelineDescriptor()
        shadowDescriptor.vertexFunction = library.makeFunction(name: "sceneModelShadowVertexShader")
        shadowDescriptor.fragmentFunction = nil
        shadowDescriptor.vertexDescriptor = vertexDescriptor
        shadowDescriptor.rasterSampleCount = 1
        shadowDescriptor.depthAttachmentPixelFormat = ShadowCascadeAtlas.depthPixelFormat
        // The caster pass writes a plain 2D depth attachment: one shadow
        // window, so no instancing and no [[render_target_array_index]].
        shadowDescriptor.inputPrimitiveTopology = .triangle
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

    func selectBelowGroundClippedPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(belowGroundClippedPipelineState)
    }

    func selectGroundFootprintPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(groundFootprintPipelineState)
    }

    func selectShadowPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(shadowPipelineState)
    }
}
