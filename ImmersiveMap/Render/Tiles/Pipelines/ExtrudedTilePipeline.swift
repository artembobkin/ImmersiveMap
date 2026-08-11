// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

class ExtrudedTilePipeline {
    /// Opaque building geometry: solid mode draws it straight into the world pass,
    /// translucent mode into the offscreen building image.
    let pipelineState: MTLRenderPipelineState
    /// Composites the building image onto the world pass with a single fullscreen
    /// triangle using premultiplied blending.
    let compositePipelineState: MTLRenderPipelineState
    /// Depth-only replay of the same geometry from the light's camera into the
    /// shadow map. No color attachments; the fragment stage only replicates the
    /// placeIn clip discard.
    let shadowPipelineState: MTLRenderPipelineState

    struct VertexIn {
        let position: SIMD3<Float>
        let normal: SIMD3<Float>
        let styleIndex: UInt8
        let _padding0: UInt8 = 0
        let _padding1: UInt8 = 0
        let _padding2: UInt8 = 0
        let surfaceID: UInt32
    }

    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int = 1) {
        let vertexFunction = library.makeFunction(name: "tileExtrudedVertexShader")
        let fragmentFunction = library.makeFunction(name: "tileExtrudedFragmentShader")

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float3
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.attributes[2].format = .uchar
        vertexDescriptor.attributes[2].offset = MemoryLayout<SIMD3<Float>>.stride * 2
        vertexDescriptor.attributes[2].bufferIndex = 0
        vertexDescriptor.attributes[3].format = .uint
        vertexDescriptor.attributes[3].offset = MemoryLayout<SIMD3<Float>>.stride * 2 + MemoryLayout<UInt32>.stride
        vertexDescriptor.attributes[3].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<VertexIn>.stride
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.rasterSampleCount = sampleCount
        pipelineDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

        let compositeDescriptor = MTLRenderPipelineDescriptor()
        compositeDescriptor.vertexFunction = library.makeFunction(name: "tileExtrudedCompositeVertexShader")
        compositeDescriptor.fragmentFunction = library.makeFunction(name: "tileExtrudedCompositeFragmentShader")
        compositeDescriptor.rasterSampleCount = sampleCount
        compositeDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        compositeDescriptor.depthAttachmentPixelFormat = .depth32Float
        // Premultiplied alpha: the building image color is already multiplied by the silhouette coverage.
        compositeDescriptor.colorAttachments[0].isBlendingEnabled = true
        compositeDescriptor.colorAttachments[0].rgbBlendOperation = .add
        compositeDescriptor.colorAttachments[0].alphaBlendOperation = .add
        compositeDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        compositeDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        compositeDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        compositeDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let shadowDescriptor = MTLRenderPipelineDescriptor()
        shadowDescriptor.vertexFunction = library.makeFunction(name: "tileExtrudedShadowVertexShader")
        shadowDescriptor.fragmentFunction = library.makeFunction(name: "tileExtrudedShadowFragmentShader")
        shadowDescriptor.vertexDescriptor = vertexDescriptor
        shadowDescriptor.rasterSampleCount = 1
        shadowDescriptor.depthAttachmentPixelFormat = ShadowCascadeAtlas.depthPixelFormat

        self.pipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
        self.compositePipelineState = try! metalDevice.makeRenderPipelineState(descriptor: compositeDescriptor)
        self.shadowPipelineState = try! metalDevice.makeRenderPipelineState(descriptor: shadowDescriptor)
    }

    func selectPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(pipelineState)
    }

    func selectCompositePipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(compositePipelineState)
    }

    func selectShadowPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(shadowPipelineState)
    }
}
