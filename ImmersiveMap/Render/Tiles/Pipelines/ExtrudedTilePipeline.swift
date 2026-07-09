// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

class ExtrudedTilePipeline {
    let pipelineState: MTLRenderPipelineState
    let winnerPipelineState: MTLRenderPipelineState

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
         layer: CAMetalLayer,
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
        pipelineDescriptor.colorAttachments[0].pixelFormat = layer.pixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
        pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let winnerDescriptor = MTLRenderPipelineDescriptor()
        winnerDescriptor.vertexFunction = vertexFunction
        winnerDescriptor.fragmentFunction = library.makeFunction(name: "tileExtrudedWinnerFragmentShader")
        winnerDescriptor.vertexDescriptor = vertexDescriptor
        winnerDescriptor.colorAttachments[0].pixelFormat = .r32Uint
        winnerDescriptor.depthAttachmentPixelFormat = .depth32Float

        self.pipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
        self.winnerPipelineState = try! metalDevice.makeRenderPipelineState(descriptor: winnerDescriptor)
    }

    func selectWinnerPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(winnerPipelineState)
    }

    func selectPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(pipelineState)
    }
}
