// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

class TilePipeline {
    let pipelineState: MTLRenderPipelineState
    /// Variant for the framebuffer-fetch world pass (Apple GPUs, nil
    /// elsewhere): identical, but declares the pass's second building
    /// attachment with an empty write mask so the pipeline stays
    /// pass-compatible.
    let withBuildingImagePipelineState: MTLRenderPipelineState?

    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int = 1,
         supportsFramebufferFetch: Bool = false) {
        let vertexFunction = library.makeFunction(name: "tileVertexShader")
        let fragmentFunction = library.makeFunction(name: "tileFragmentShader")
        
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .short2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .uchar
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD2<Int16>>.size
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.attributes[2].format = .uchar
        vertexDescriptor.attributes[2].offset = MemoryLayout<SIMD2<Int16>>.size + 1
        vertexDescriptor.attributes[2].bufferIndex = 0
        vertexDescriptor.attributes[3].format = .short
        vertexDescriptor.attributes[3].offset = MemoryLayout<SIMD2<Int16>>.size + 2
        vertexDescriptor.attributes[3].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<TileVertexIn>.stride
        vertexDescriptor.layouts[0].stepFunction = .perVertex
        
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.rasterSampleCount = sampleCount
        
        
        pipelineDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        // Alpha blends with .one so coverage accumulates on a transparent
        // destination; over an opaque one the result is unchanged.
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        
        self.pipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)

        if supportsFramebufferFetch {
            pipelineDescriptor.colorAttachments[1].pixelFormat = pixelFormat
            pipelineDescriptor.colorAttachments[1].writeMask = []
            self.withBuildingImagePipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } else {
            self.withBuildingImagePipelineState = nil
        }
    }

    func selectPipeline(renderEncoder: MTLRenderCommandEncoder,
                        withBuildingImageAttachment: Bool = false) {
        if withBuildingImageAttachment, let withBuildingImagePipelineState {
            renderEncoder.setRenderPipelineState(withBuildingImagePipelineState)
            return
        }
        renderEncoder.setRenderPipelineState(pipelineState)
    }
}
