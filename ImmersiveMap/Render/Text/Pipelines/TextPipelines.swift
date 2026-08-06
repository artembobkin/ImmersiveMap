// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// The four pipelines that draw from the glyph atlas: screen-space text, base
/// labels, road labels bent along their path, and POI sprites. They share the
/// alpha blending that keeps MSDF edges antialiased.
final class TextPipelines {
    /// Screen-space text laid out as `TextVertex` (debug overlay, watermarks).
    let text: MTLRenderPipelineState
    /// Base labels laid out as `LabelVertex` and placed from the label buffers.
    let label: MTLRenderPipelineState
    /// Road labels: the same vertices bent along the road path.
    let roadLabel: MTLRenderPipelineState
    /// POI sprites, drawn from the sprite atlas with the label geometry.
    let poiIcon: MTLRenderPipelineState

    init(device: MTLDevice,
         library: MTLLibrary,
         sampleCount: Int) {
        guard let textVertexFn = library.makeFunction(name: "textVertex"),
              let labelVertexFn = library.makeFunction(name: "labelTextVertex"),
              let roadLabelVertexFn = library.makeFunction(name: "roadLabelTextVertex"),
              let poiIconVertexFn = library.makeFunction(name: "poiSpriteVertex"),
              let poiIconFragmentFn = library.makeFunction(name: "poiSpriteFragment"),
              let fragmentFn = library.makeFunction(name: "textFragment"),
              let roadFragmentFn = library.makeFunction(name: "roadTextFragment") else { fatalError("Functions not found") }

        let textVertexDescriptor = MTLVertexDescriptor()
        textVertexDescriptor.attributes[0].format = .float4
        textVertexDescriptor.attributes[0].offset = 0
        textVertexDescriptor.attributes[0].bufferIndex = 0
        textVertexDescriptor.attributes[1].format = .float2
        textVertexDescriptor.attributes[1].offset = MemoryLayout<SIMD4<Float>>.stride
        textVertexDescriptor.attributes[1].bufferIndex = 0
        textVertexDescriptor.layouts[0].stride = MemoryLayout<TextVertex>.stride

        let labelVertexDescriptor = MTLVertexDescriptor()
        labelVertexDescriptor.attributes[0].format = .float2
        labelVertexDescriptor.attributes[0].offset = MemoryLayout<LabelVertex>.offset(of: \LabelVertex.position) ?? 0
        labelVertexDescriptor.attributes[0].bufferIndex = 0
        labelVertexDescriptor.attributes[1].format = .float2
        labelVertexDescriptor.attributes[1].offset = MemoryLayout<LabelVertex>.offset(of: \LabelVertex.uv) ?? 0
        labelVertexDescriptor.attributes[1].bufferIndex = 0
        labelVertexDescriptor.attributes[2].format = .int
        labelVertexDescriptor.attributes[2].offset = MemoryLayout<LabelVertex>.offset(of: \LabelVertex.labelIndex) ?? 0
        labelVertexDescriptor.attributes[2].bufferIndex = 0
        labelVertexDescriptor.attributes[3].format = .float2
        labelVertexDescriptor.attributes[3].offset = MemoryLayout<LabelVertex>.offset(of: \LabelVertex.spriteUV) ?? 0
        labelVertexDescriptor.attributes[3].bufferIndex = 0
        labelVertexDescriptor.layouts[0].stride = MemoryLayout<LabelVertex>.stride

        do {
            self.text = try Self.makePipelineState(device: device,
                                                   sampleCount: sampleCount,
                                                   vertexFunction: textVertexFn,
                                                   vertexDescriptor: textVertexDescriptor,
                                                   fragmentFunction: fragmentFn)
            self.label = try Self.makePipelineState(device: device,
                                                    sampleCount: sampleCount,
                                                    vertexFunction: labelVertexFn,
                                                    vertexDescriptor: labelVertexDescriptor,
                                                    fragmentFunction: fragmentFn)
            self.roadLabel = try Self.makePipelineState(device: device,
                                                        sampleCount: sampleCount,
                                                        vertexFunction: roadLabelVertexFn,
                                                        vertexDescriptor: labelVertexDescriptor,
                                                        fragmentFunction: roadFragmentFn)
            self.poiIcon = try Self.makePipelineState(device: device,
                                                      sampleCount: sampleCount,
                                                      vertexFunction: poiIconVertexFn,
                                                      vertexDescriptor: labelVertexDescriptor,
                                                      fragmentFunction: poiIconFragmentFn)
        } catch {
            fatalError("Pipeline creation failed: \(error)")
        }
    }

    private static func makePipelineState(device: MTLDevice,
                                          sampleCount: Int,
                                          vertexFunction: MTLFunction,
                                          vertexDescriptor: MTLVertexDescriptor,
                                          fragmentFunction: MTLFunction) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.rasterSampleCount = sampleCount
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.depthAttachmentPixelFormat = .depth32Float
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        // Alpha blends with .one so glyph coverage accumulates on a transparent
        // destination; over an opaque one the result is unchanged.
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }
}
