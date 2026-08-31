// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

class TilePipeline {
    /// Which surface the pipeline draws tiles onto. The flat one projects
    /// through a model matrix into the plane (Tile.metal); the sphere one
    /// projects tile-local positions onto the globe through the surface
    /// morph (TileSphere.metal). Same vertex format, styles and blending.
    enum Surface {
        case flat
        case sphere
    }

    let pipelineState: MTLRenderPipelineState
    /// Variant for the framebuffer-fetch world pass (Apple GPUs, nil
    /// elsewhere): identical, but declares the pass's second building
    /// attachment with an empty write mask so the pipeline stays
    /// pass-compatible.
    let withBuildingImagePipelineState: MTLRenderPipelineState?
    /// Sphere surface only: the unlit fragment for the deferred-lighting
    /// world, where the ground layers blend bare style colours and the
    /// globeSurfaceLighting pass lights the blend once per pixel. Its vertex
    /// stage is the pure-sphere specialization: the deferred gate implies
    /// transition 0.
    let sphereUnlitPipelineState: MTLRenderPipelineState?
    /// Sphere surface only: inline lighting with the pure-sphere vertex
    /// stage, for frames at transition 0 that still light inline (the deep
    /// tone below zoom 2).
    let sphereLitPurePipelineState: MTLRenderPipelineState?

    /// - Parameter readsGroundShadowMask: the flat world pass reads the
    ///   per-pixel ground shadow mask at fragment texture 1; the globe atlas
    ///   bake keeps the direct cascade sampling path (with a disabled uniform)
    ///   and only binds the shadow map slot.
    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int = 1,
         supportsFramebufferFetch: Bool = false,
         readsGroundShadowMask: Bool = false,
         surface: Surface = .flat) {
        let vertexFunction: MTLFunction?
        let fragmentFunction: MTLFunction?
        var sphereUnlitFragmentFunction: MTLFunction?
        var sphereUnlitPureVertexFunction: MTLFunction?
        var sphereLitPureVertexFunction: MTLFunction?
        switch surface {
        case .flat:
            vertexFunction = library.makeFunction(name: "tileVertexShader")
            let constantValues = MTLFunctionConstantValues()
            var readsMask = readsGroundShadowMask
            constantValues.setConstantValue(&readsMask, type: .bool, index: 0)
            fragmentFunction = try! library.makeFunction(name: "tileFragmentShader", constantValues: constantValues)
        case .sphere:
            // The vertex stage carries two constants: lit-inline (index 0,
            // the lit-only varyings exist exactly when the fragment reads
            // them) and pure-sphere (index 1, the morph folds away at
            // transition 0). The fragment reads only the first.
            func sphereVertex(litInline: Bool, pureSphere: Bool) -> MTLFunction {
                let values = MTLFunctionConstantValues()
                var lit = litInline
                var pure = pureSphere
                values.setConstantValue(&lit, type: .bool, index: 0)
                values.setConstantValue(&pure, type: .bool, index: 1)
                return try! library.makeFunction(name: "tileSphereVertexShader", constantValues: values)
            }
            func sphereFragment(litInline: Bool) -> MTLFunction {
                let values = MTLFunctionConstantValues()
                var lit = litInline
                values.setConstantValue(&lit, type: .bool, index: 0)
                return try! library.makeFunction(name: "tileSphereFragmentShader", constantValues: values)
            }
            vertexFunction = sphereVertex(litInline: true, pureSphere: false)
            fragmentFunction = sphereFragment(litInline: true)
            sphereLitPureVertexFunction = sphereVertex(litInline: true, pureSphere: true)
            sphereUnlitPureVertexFunction = sphereVertex(litInline: false, pureSphere: true)
            sphereUnlitFragmentFunction = sphereFragment(litInline: false)
        }
        
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .short2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .uchar
        vertexDescriptor.attributes[1].offset = MemoryLayout<SIMD2<Int16>>.size
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.attributes[2].format = .char
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

        if let sphereUnlitPureVertexFunction, let sphereLitPureVertexFunction, let sphereUnlitFragmentFunction {
            pipelineDescriptor.vertexFunction = sphereUnlitPureVertexFunction
            pipelineDescriptor.fragmentFunction = sphereUnlitFragmentFunction
            self.sphereUnlitPipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
            pipelineDescriptor.vertexFunction = sphereLitPureVertexFunction
            pipelineDescriptor.fragmentFunction = fragmentFunction
            self.sphereLitPurePipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
            pipelineDescriptor.vertexFunction = vertexFunction
        } else {
            self.sphereUnlitPipelineState = nil
            self.sphereLitPurePipelineState = nil
        }

        if supportsFramebufferFetch, surface == .flat {
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

    /// The sphere variant for the frame: unlit implies the pure sphere (the
    /// deferred gate requires transition 0); lit picks the pure-sphere
    /// vertex stage when the frame is at transition 0. Falls back to the
    /// full pipeline on a surface that has no variants.
    func selectSpherePipeline(renderEncoder: MTLRenderCommandEncoder,
                              litInline: Bool,
                              pureSphere: Bool) {
        if litInline == false, let sphereUnlitPipelineState {
            renderEncoder.setRenderPipelineState(sphereUnlitPipelineState)
            return
        }
        if pureSphere, let sphereLitPurePipelineState {
            renderEncoder.setRenderPipelineState(sphereLitPurePipelineState)
            return
        }
        renderEncoder.setRenderPipelineState(pipelineState)
    }
}
