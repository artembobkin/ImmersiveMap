// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

final class StarfieldPipeline {
    private struct StarVertex {
        let position: SIMD3<Float>
        let size: Float
        let brightness: Float
        let temperature: Float
        let twinklePhase: Float
        let halo: Float
    }

    let starsPipelineState: MTLRenderPipelineState

    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int = 1) {
        let vertexFunction = library.makeFunction(name: "starfieldVertexShader")
        let fragmentFunction = library.makeFunction(name: "starfieldFragmentShader")

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD3<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.attributes[2].format = .float
        vertexDescriptor.attributes[2].offset = MemoryLayout<SIMD3<Float>>.stride + MemoryLayout<Float>.stride
        vertexDescriptor.attributes[2].bufferIndex = 0
        vertexDescriptor.attributes[3].format = .float
        vertexDescriptor.attributes[3].offset = MemoryLayout<SIMD3<Float>>.stride + MemoryLayout<Float>.stride * 2
        vertexDescriptor.attributes[3].bufferIndex = 0
        vertexDescriptor.attributes[4].format = .float
        vertexDescriptor.attributes[4].offset = MemoryLayout<SIMD3<Float>>.stride + MemoryLayout<Float>.stride * 3
        vertexDescriptor.attributes[4].bufferIndex = 0
        vertexDescriptor.attributes[5].format = .float
        vertexDescriptor.attributes[5].offset = MemoryLayout<SIMD3<Float>>.stride + MemoryLayout<Float>.stride * 4
        vertexDescriptor.attributes[5].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<StarVertex>.stride
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.rasterSampleCount = sampleCount
        pipelineDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
        pipelineDescriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        // Additive stars, with .one for the alpha channel: coverage accumulates
        // like the color instead of being squared by the source alpha.
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one

        do {
            starsPipelineState = try metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            fatalError("Failed to create starfield pipeline: \(error)")
        }
    }

    func selectStarsPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(starsPipelineState)
    }
}
