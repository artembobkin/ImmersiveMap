// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Metal
import simd

struct TextStyleUniform: Equatable {
    var textColor: SIMD3<Float>
    /// How far the letters are grown past the font's outline, in pixels.
    var fillBiasPx: Float
    var strokeColor: SIMD3<Float>
    var strokeWidthPx: Float
    /// The opacity of the fill and the halo, 1 solid
    /// (`LabelTextStyle.opacity`).
    var opacity: Float
    /// The share of the halo's width over which it fades out, 0 solid to
    /// its edge (`LabelTextStyle.haloSoftness`).
    var haloSoftness: Float

    init(textColor: SIMD3<Float>,
         strokeColor: SIMD3<Float> = SIMD3<Float>(1.0, 1.0, 1.0),
         strokeWidthPx: Float = 2.0,
         fillBiasPx: Float = 0.75,
         opacity: Float = 1,
         haloSoftness: Float = 0) {
        self.textColor = textColor
        self.fillBiasPx = fillBiasPx
        self.strokeColor = strokeColor
        self.strokeWidthPx = strokeWidthPx
        self.opacity = opacity
        self.haloSoftness = haloSoftness
    }
}

/// The pipeline of plain text: glyph quads at screen positions
/// (`TextVertex`), as the debug overlay draws its lines. One set for the
/// process. Text draws in passes of one sample.
final class TextPipeline: SharedGPUResources {
    let pipelineState: MTLRenderPipelineState

    init(device: MTLDevice, library: MTLLibrary) {
        guard let vertexFunction = library.makeFunction(name: "textVertex"),
              let fragmentFunction = library.makeFunction(name: "textFragment") else {
            fatalError("Functions not found")
        }
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float4
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float2
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD4<Float>>.stride
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<TextVertex>.stride
        do {
            pipelineState = try Self.makePipelineState(device: device,
                                                       vertexFunction: vertexFunction,
                                                       vertexDescriptor: vertexDescriptor,
                                                       fragmentFunction: fragmentFunction)
        } catch {
            fatalError("Pipeline creation failed: \(error)")
        }
    }

    static func make(_ build: SharedGPUResourceBuild) -> TextPipeline {
        TextPipeline(device: build.device, library: build.library)
    }

    /// A pipeline that blends glyphs of the atlas over the frame: what the
    /// plain text and the labels' pipelines (`LabelPipelines`) have in
    /// common.
    static func makePipelineState(device: MTLDevice,
                                  vertexFunction: MTLFunction,
                                  vertexDescriptor: MTLVertexDescriptor,
                                  fragmentFunction: MTLFunction,
                                  sampleCount: Int = 1) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.rasterSampleCount = sampleCount
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
        descriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        // Alpha blends with .one so glyph coverage accumulates on a transparent
        // destination. Over an opaque one the result is unchanged.
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }
}
