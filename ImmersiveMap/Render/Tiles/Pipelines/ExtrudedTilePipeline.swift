// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

class ExtrudedTilePipeline {
    /// Opaque building geometry, straight into the world pass.
    let pipelineState: MTLRenderPipelineState
    /// Depth-only replay of the same geometry from the light's camera into the
    /// shadow map. No color attachments and no fragment stage: the placeIn
    /// clip rides on the vertex stage's clip distances.
    let shadowPipelineState: MTLRenderPipelineState

    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int = 1) {
        let vertexFunction = library.makeFunction(name: "tileExtrudedVertexShader")
        let fragmentFunction = library.makeFunction(name: "tileExtrudedFragmentShader")

        // The 12-byte layout of TileMvtParser.ExtrudedVertexIn: quantized
        // positions fed as raw Int16 triples (the fetch converts integer
        // formats to float with the numeric value; the shader applies the
        // inverse fixed-point scale), normals as char3Normalized.
        assert(MemoryLayout<TileMvtParser.ExtrudedVertexIn>.stride == 12,
               "The vertex descriptor mirrors ExtrudedVertexIn byte for byte")
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .short3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .char3Normalized
        vertexDescriptor.attributes[1].offset = 6
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.attributes[2].format = .uchar
        vertexDescriptor.attributes[2].offset = 9
        vertexDescriptor.attributes[2].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<TileMvtParser.ExtrudedVertexIn>.stride
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.rasterSampleCount = sampleCount
        pipelineDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
        pipelineDescriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8

        let shadowDescriptor = MTLRenderPipelineDescriptor()
        shadowDescriptor.vertexFunction = library.makeFunction(name: "tileExtrudedShadowVertexShader")
        shadowDescriptor.fragmentFunction = nil
        shadowDescriptor.vertexDescriptor = vertexDescriptor
        shadowDescriptor.rasterSampleCount = 1
        shadowDescriptor.depthAttachmentPixelFormat = ShadowCascadeAtlas.depthPixelFormat
        // The caster pass writes a plain 2D depth attachment: one shadow
        // window, so no instancing and no [[render_target_array_index]].
        shadowDescriptor.inputPrimitiveTopology = .triangle

        self.pipelineState = try! metalDevice.makeArchivedRenderPipelineState(descriptor: pipelineDescriptor)
        self.shadowPipelineState = try! metalDevice.makeArchivedRenderPipelineState(descriptor: shadowDescriptor)
    }

    func selectPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(pipelineState)
    }

    func selectShadowPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(shadowPipelineState)
    }
}
