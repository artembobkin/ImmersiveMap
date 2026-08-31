// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

class GlobePipeline {
    let pipelineState: MTLRenderPipelineState
    /// The unlit fill for the deferred-lighting world: same geometry and
    /// color, no globeSurfaceShade; the globeSurfaceLighting pass lights it
    /// with everything blended over it, once per pixel. Its vertex stage is
    /// the pure-sphere specialization: the deferred gate implies
    /// transition 0.
    let unlitPipelineState: MTLRenderPipelineState
    /// Inline lighting with the pure-sphere vertex stage, for transition-0
    /// frames that still light inline (the deep tone below zoom 2).
    let litPurePipelineState: MTLRenderPipelineState
    
    /// The placeholder fill of the globe surface: the sphere grid of one tile
    /// slot in the map colour, which writes the surface depth under the tile
    /// geometry drawn on the sphere (TileSphere.metal).
    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int = 1) {
        // The vertex stage carries two constants: lit-inline (index 0, the
        // lit-only varyings exist exactly when the fragment reads them) and
        // pure-sphere (index 1, the morph folds away at transition 0). The
        // fragment reads only the first.
        func placeholderVertex(litInline: Bool, pureSphere: Bool) -> MTLFunction {
            let values = MTLFunctionConstantValues()
            var lit = litInline
            var pure = pureSphere
            values.setConstantValue(&lit, type: .bool, index: 0)
            values.setConstantValue(&pure, type: .bool, index: 1)
            return try! library.makeFunction(name: "globeVertexShader", constantValues: values)
        }
        func placeholderFragment(litInline: Bool) -> MTLFunction {
            let values = MTLFunctionConstantValues()
            var lit = litInline
            values.setConstantValue(&lit, type: .bool, index: 0)
            return try! library.makeFunction(name: "globeSurfacePlaceholderFragmentShader", constantValues: values)
        }
        let vertexFunction = placeholderVertex(litInline: true, pureSphere: false)
        let fragmentFunction = placeholderFragment(litInline: true)
        let litPureVertexFunction = placeholderVertex(litInline: true, pureSphere: true)
        let unlitVertexFunction = placeholderVertex(litInline: false, pureSphere: true)
        let unlitFragmentFunction = placeholderFragment(litInline: false)
        
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<SphereGeometry.Vertex>.stride
        vertexDescriptor.layouts[0].stepFunction = .perVertex
        
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.rasterSampleCount = sampleCount
        
        pipelineDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
        
        self.pipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)

        pipelineDescriptor.vertexFunction = unlitVertexFunction
        pipelineDescriptor.fragmentFunction = unlitFragmentFunction
        self.unlitPipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)

        pipelineDescriptor.vertexFunction = litPureVertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        self.litPurePipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }
    
    func selectPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(pipelineState)
    }

    /// The variant for the frame: unlit implies the pure sphere (the
    /// deferred gate requires transition 0); lit picks the pure-sphere
    /// vertex stage when the frame is at transition 0.
    func selectPipeline(renderEncoder: MTLRenderCommandEncoder,
                        litInline: Bool,
                        pureSphere: Bool) {
        if litInline == false {
            renderEncoder.setRenderPipelineState(unlitPipelineState)
            return
        }
        renderEncoder.setRenderPipelineState(pureSphere ? litPurePipelineState : pipelineState)
    }
}
