// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// The fullscreen pass that paints the air around the surface's edge: the
/// globe's atmosphere and limb feather, the flat map's fog band. One
/// fragment function behind a side constant, two depth tests around it (see
/// `HorizonRenderSubsystem`), and, like every pipeline of the world pass, a
/// twin that declares the framebuffer-fetch building image attachment.
final class HorizonPipeline {
    let skyPipelineState: MTLRenderPipelineState
    let groundPipelineState: MTLRenderPipelineState
    let skyWithBuildingImagePipelineState: MTLRenderPipelineState?
    let groundWithBuildingImagePipelineState: MTLRenderPipelineState?

    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int = 1,
         supportsFramebufferFetch: Bool = false) {
        func makeFragment(groundSide: Bool) -> MTLFunction {
            let constants = MTLFunctionConstantValues()
            var value = groundSide
            constants.setConstantValue(&value, type: .bool, index: 0)
            do {
                return try library.makeFunction(name: "horizonFragmentShader", constantValues: constants)
            } catch {
                fatalError("Failed to specialize the horizon fragment shader: \(error)")
            }
        }
        func makeState(groundSide: Bool, withBuildingImage: Bool) -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = groundSide ? "HorizonGroundPipeline" : "HorizonSkyPipeline"
            descriptor.vertexFunction = library.makeFunction(name: "horizonVertexShader")
            descriptor.fragmentFunction = makeFragment(groundSide: groundSide)
            descriptor.rasterSampleCount = sampleCount
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            descriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
            descriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
            // Premultiplied "over": the shader hands out the tint already
            // weighted by its coverage, and the coverage in alpha, so the
            // haze covers the edge and thins to nothing away from it. Alpha
            // composes the same way, which keeps the frame's own coverage
            // right where space is transparent.
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            if withBuildingImage {
                descriptor.colorAttachments[1].pixelFormat = pixelFormat
                descriptor.colorAttachments[1].writeMask = []
            }
            do {
                return try metalDevice.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                fatalError("Failed to create the horizon pipeline: \(error)")
            }
        }
        skyPipelineState = makeState(groundSide: false, withBuildingImage: false)
        groundPipelineState = makeState(groundSide: true, withBuildingImage: false)
        if supportsFramebufferFetch {
            skyWithBuildingImagePipelineState = makeState(groundSide: false, withBuildingImage: true)
            groundWithBuildingImagePipelineState = makeState(groundSide: true, withBuildingImage: true)
        } else {
            skyWithBuildingImagePipelineState = nil
            groundWithBuildingImagePipelineState = nil
        }
    }

    func pipelineState(groundSide: Bool, withBuildingImageAttachment: Bool) -> MTLRenderPipelineState {
        if withBuildingImageAttachment {
            if groundSide, let groundWithBuildingImagePipelineState {
                return groundWithBuildingImagePipelineState
            }
            if groundSide == false, let skyWithBuildingImagePipelineState {
                return skyWithBuildingImagePipelineState
            }
        }
        return groundSide ? groundPipelineState : skyPipelineState
    }
}

/// Draws one side of the horizon layer: a fullscreen triangle at the far
/// plane whose fragment stage resolves, per pixel, the view ray's angle
/// above or below the edge and paints the haze there. Stateless beyond the
/// pipeline; every frame's parameters arrive as one uniform.
final class HorizonRenderer {
    private let pipeline: HorizonPipeline

    init(pipeline: HorizonPipeline) {
        self.pipeline = pipeline
    }

    func draw(renderEncoder: MTLRenderCommandEncoder,
              uniform: HorizonUniform,
              groundSide: Bool,
              withBuildingImageAttachment: Bool) {
        var uniformValue = uniform
        renderEncoder.setRenderPipelineState(pipeline.pipelineState(groundSide: groundSide,
                                                                    withBuildingImageAttachment: withBuildingImageAttachment))
        renderEncoder.setCullMode(.none)
        renderEncoder.setFragmentBytes(&uniformValue,
                                       length: MemoryLayout<HorizonUniform>.stride,
                                       index: 0)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}
