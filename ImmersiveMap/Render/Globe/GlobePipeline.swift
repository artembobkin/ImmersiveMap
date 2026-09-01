// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

class GlobePipeline {
    /// The lit morph fill, for the unfurl: the only frames that light inline.
    let pipelineState: MTLRenderPipelineState
    /// The unlit fill of the pure sphere: same geometry and color, no
    /// globeSurfaceShade; the globeSurfaceLighting pass lights it with
    /// everything blended over it, once per pixel. Its vertex stage is the
    /// pure-sphere specialization: the deferred gate is transition 0.
    let unlitPipelineState: MTLRenderPipelineState
    /// Depth-only fills, no fragment stage at all: what a slot draws when a
    /// tile placement already paints every pixel of it, so the surface depth
    /// is still written but nothing is shaded just to be painted over. One
    /// per vertex path (pure sphere, morph).
    let depthOnlyPurePipelineState: MTLRenderPipelineState
    let depthOnlyMorphPipelineState: MTLRenderPipelineState

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
        let litMorphVertexFunction = placeholderVertex(litInline: true, pureSphere: false)
        let litFragmentFunction = placeholderFragment(litInline: true)
        let unlitPureVertexFunction = placeholderVertex(litInline: false, pureSphere: true)
        let unlitMorphVertexFunction = placeholderVertex(litInline: false, pureSphere: false)
        let unlitFragmentFunction = placeholderFragment(litInline: false)

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = MemoryLayout<SphereGeometry.Vertex>.stride
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = litMorphVertexFunction
        pipelineDescriptor.fragmentFunction = litFragmentFunction
        pipelineDescriptor.vertexDescriptor = vertexDescriptor
        pipelineDescriptor.rasterSampleCount = sampleCount

        pipelineDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

        self.pipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)

        pipelineDescriptor.vertexFunction = unlitPureVertexFunction
        pipelineDescriptor.fragmentFunction = unlitFragmentFunction
        self.unlitPipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)

        // No fragment stage: the rasterizer writes depth and nothing else.
        pipelineDescriptor.fragmentFunction = nil
        pipelineDescriptor.colorAttachments[0].writeMask = []
        pipelineDescriptor.vertexFunction = unlitPureVertexFunction
        self.depthOnlyPurePipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
        pipelineDescriptor.vertexFunction = unlitMorphVertexFunction
        self.depthOnlyMorphPipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    /// The colour variant for the frame: the pure sphere blends unlit under
    /// the deferred lighting pass, the unfurl lights inline.
    func selectPipeline(renderEncoder: MTLRenderCommandEncoder,
                        pureSphere: Bool) {
        renderEncoder.setRenderPipelineState(pureSphere ? unlitPipelineState : pipelineState)
    }

    /// The depth-only variant for a slot a tile placement already paints.
    func selectDepthOnlyPipeline(renderEncoder: MTLRenderCommandEncoder,
                                 pureSphere: Bool) {
        renderEncoder.setRenderPipelineState(pureSphere ? depthOnlyPurePipelineState : depthOnlyMorphPipelineState)
    }
}
