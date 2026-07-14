// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import MetalKit

/// Пайплайн конуса-луча от геоточки к сдвинутому кружку; рисуется в
/// overlay-пассе до пузырей аватаров.
final class AvatarBeamPipeline {
    let beamPipelineState: MTLRenderPipelineState

    init(metalDevice: MTLDevice,
         layer: CAMetalLayer,
         library: MTLLibrary,
         sampleCount: Int = 1) {
        self.beamPipelineState = Self.makePipelineState(metalDevice: metalDevice,
                                                        layer: layer,
                                                        library: library,
                                                        sampleCount: sampleCount,
                                                        vertexFunctionName: "avatarBeamVertex",
                                                        fragmentFunctionName: "avatarBeamFragment")
    }

    func selectBeamPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(beamPipelineState)
    }

    private static func makePipelineState(metalDevice: MTLDevice,
                                          layer: CAMetalLayer,
                                          library: MTLLibrary,
                                          sampleCount: Int,
                                          vertexFunctionName: String,
                                          fragmentFunctionName: String) -> MTLRenderPipelineState {
        let vertexFunction = library.makeFunction(name: vertexFunctionName)
        let fragmentFunction = library.makeFunction(name: fragmentFunctionName)

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
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

        return try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
}
