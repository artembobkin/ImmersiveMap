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
    /// The same two with the ground relief (TileExtruded.metal,
    /// kExtrudedRelief): each building lifted by its tile's lifts in
    /// metres at vertex buffer 4, times the world units a metre spans at
    /// vertex buffer 5, for the tiles whose terrain is in.
    let reliefPipelineState: MTLRenderPipelineState
    let reliefShadowPipelineState: MTLRenderPipelineState

    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int = 1) {
        func function(_ name: String, relief: Bool) -> MTLFunction {
            let values = MTLFunctionConstantValues()
            var reliefValue = relief
            values.setConstantValue(&reliefValue, type: .bool, index: 0)
            return try! library.makeFunction(name: name, constantValues: values)
        }
        let vertexFunction = function("tileExtrudedVertexShader", relief: false)
        let fragmentFunction = library.makeFunction(name: "tileExtrudedFragmentShader")

        // The 12-byte layout of ExtrudedVertexIn: quantized positions fed
        // as raw Int16 triples (the fetch converts integer formats to float
        // with the numeric value; the shader applies the inverse fixed-point
        // scale), normals as char3Normalized, the style index, and two
        // bytes of padding to the stride Metal requires.
        assert(MemoryLayout<ExtrudedVertexIn>.stride == 12,
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
        vertexDescriptor.attributes[3].format = .ushort
        vertexDescriptor.attributes[3].offset = 10
        vertexDescriptor.attributes[3].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<ExtrudedVertexIn>.stride
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
        shadowDescriptor.vertexFunction = function("tileExtrudedShadowVertexShader", relief: false)
        shadowDescriptor.fragmentFunction = nil
        shadowDescriptor.vertexDescriptor = vertexDescriptor
        shadowDescriptor.rasterSampleCount = 1
        shadowDescriptor.depthAttachmentPixelFormat = ShadowCascadeAtlas.depthPixelFormat
        // The caster pass writes a plain 2D depth attachment: one shadow
        // window, so no instancing and no [[render_target_array_index]].
        shadowDescriptor.inputPrimitiveTopology = .triangle

        self.pipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
        self.shadowPipelineState = try! metalDevice.makeRenderPipelineState(descriptor: shadowDescriptor)
        pipelineDescriptor.vertexFunction = function("tileExtrudedVertexShader", relief: true)
        self.reliefPipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
        shadowDescriptor.vertexFunction = function("tileExtrudedShadowVertexShader", relief: true)
        self.reliefShadowPipelineState = try! metalDevice.makeRenderPipelineState(descriptor: shadowDescriptor)
    }

    /// `relief` for a tile whose lifts are bound at vertex buffer 4.
    func selectPipeline(renderEncoder: MTLRenderCommandEncoder, relief: Bool = false) {
        renderEncoder.setRenderPipelineState(relief ? reliefPipelineState : pipelineState)
    }

    func selectShadowPipeline(renderEncoder: MTLRenderCommandEncoder, relief: Bool = false) {
        renderEncoder.setRenderPipelineState(relief ? reliefShadowPipelineState : shadowPipelineState)
    }
}
