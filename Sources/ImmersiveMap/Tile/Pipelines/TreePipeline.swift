// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

/// The trees of the flat map (Trees.metal): the tree model drawn once per
/// instance of a tile, opaque, straight into the world pass as the
/// buildings are, and their shadows, a soft disc under each on the
/// ground, blended over it after the roads.
class TreePipeline {
    let pipelineState: MTLRenderPipelineState
    /// The shadow discs: a quad per instance from the vertex index, no
    /// vertex buffer, multiplied into the ground (the colour it writes is
    /// the darkening, `shadowColorMultiplier`).
    let shadowPipelineState: MTLRenderPipelineState

    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int = 1) {
        // The 20-byte vertex of the model file (`TreeModelContents`): the
        // position in metres, the normal as signed bytes with a padding
        // byte, the shading as four bytes.
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .char4Normalized
        vertexDescriptor.attributes[1].offset = 12
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.attributes[2].format = .uchar4Normalized
        vertexDescriptor.attributes[2].offset = 16
        vertexDescriptor.attributes[2].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = TreeModelContents.vertexStride
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "treeVertexShader")
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "treeFragmentShader")
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.rasterSampleCount = sampleCount
        pipelineDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
        pipelineDescriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
        self.pipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)

        let shadowDescriptor = MTLRenderPipelineDescriptor()
        shadowDescriptor.vertexFunction = library.makeFunction(name: "treeShadowVertexShader")
        shadowDescriptor.fragmentFunction = library.makeFunction(name: "treeShadowFragmentShader")
        shadowDescriptor.rasterSampleCount = sampleCount
        shadowDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        shadowDescriptor.colorAttachments[0].isBlendingEnabled = true
        shadowDescriptor.colorAttachments[0].rgbBlendOperation = .add
        shadowDescriptor.colorAttachments[0].sourceRGBBlendFactor = .destinationColor
        shadowDescriptor.colorAttachments[0].destinationRGBBlendFactor = .zero
        shadowDescriptor.colorAttachments[0].alphaBlendOperation = .add
        shadowDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .zero
        shadowDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
        shadowDescriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
        shadowDescriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
        self.shadowPipelineState = try! metalDevice.makeRenderPipelineState(descriptor: shadowDescriptor)
    }
}
