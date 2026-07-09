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

    let backgroundPipelineState: MTLRenderPipelineState
    let starsPipelineState: MTLRenderPipelineState
    let sunPipelineState: MTLRenderPipelineState

    init(metalDevice: MTLDevice,
         layer: CAMetalLayer,
         library: MTLLibrary,
         sampleCount: Int = 1) {
        let backgroundVertexFunction = library.makeFunction(name: "starfieldBackgroundVertexShader")
        let backgroundFragmentFunction = library.makeFunction(name: "starfieldBackgroundFragmentShader")
        let sunVertexFunction = library.makeFunction(name: "sunVertexShader")
        let sunFragmentFunction = library.makeFunction(name: "sunFragmentShader")
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

        let backgroundDescriptor = MTLRenderPipelineDescriptor()
        backgroundDescriptor.vertexFunction = backgroundVertexFunction
        backgroundDescriptor.fragmentFunction = backgroundFragmentFunction
        backgroundDescriptor.rasterSampleCount = sampleCount
        backgroundDescriptor.colorAttachments[0].pixelFormat = layer.pixelFormat
        backgroundDescriptor.depthAttachmentPixelFormat = .depth32Float

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.rasterSampleCount = sampleCount
        pipelineDescriptor.colorAttachments[0].pixelFormat = layer.pixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one

        let sunDescriptor = MTLRenderPipelineDescriptor()
        sunDescriptor.vertexFunction = sunVertexFunction
        sunDescriptor.fragmentFunction = sunFragmentFunction
        sunDescriptor.rasterSampleCount = sampleCount
        sunDescriptor.colorAttachments[0].pixelFormat = layer.pixelFormat
        sunDescriptor.depthAttachmentPixelFormat = .depth32Float
        sunDescriptor.colorAttachments[0].isBlendingEnabled = true
        sunDescriptor.colorAttachments[0].rgbBlendOperation = .add
        sunDescriptor.colorAttachments[0].alphaBlendOperation = .add
        sunDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        sunDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        sunDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        sunDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one

        do {
            backgroundPipelineState = try metalDevice.makeRenderPipelineState(descriptor: backgroundDescriptor)
            starsPipelineState = try metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
            sunPipelineState = try metalDevice.makeRenderPipelineState(descriptor: sunDescriptor)
        } catch {
            fatalError("Failed to create starfield pipeline: \(error)")
        }
    }

    func selectBackgroundPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(backgroundPipelineState)
    }

    func selectStarsPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(starsPipelineState)
    }

    func selectSunPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(sunPipelineState)
    }
}
