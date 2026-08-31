// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

class GlobePipeline {
    let pipelineState: MTLRenderPipelineState
    /// The unlit fill for the deferred-lighting world: same geometry and
    /// color, no globeSurfaceShade; the globeSurfaceLighting pass lights it
    /// with everything blended over it, once per pixel.
    let unlitPipelineState: MTLRenderPipelineState
    
    /// The placeholder fill of the globe surface: the sphere grid of one tile
    /// slot in the map colour, which writes the surface depth under the tile
    /// geometry drawn on the sphere (TileSphere.metal).
    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int = 1) {
        let litValues = MTLFunctionConstantValues()
        var litInline = true
        litValues.setConstantValue(&litInline, type: .bool, index: 0)
        // The vertex stage carries the constant too: the lit-only varyings
        // exist in its output struct exactly when the fragment reads them.
        let vertexFunction = try! library.makeFunction(name: "globeVertexShader",
                                                       constantValues: litValues)
        let fragmentFunction = try! library.makeFunction(name: "globeSurfacePlaceholderFragmentShader",
                                                         constantValues: litValues)
        let unlitValues = MTLFunctionConstantValues()
        var unlitInline = false
        unlitValues.setConstantValue(&unlitInline, type: .bool, index: 0)
        let unlitVertexFunction = try! library.makeFunction(name: "globeVertexShader",
                                                            constantValues: unlitValues)
        let unlitFragmentFunction = try! library.makeFunction(name: "globeSurfacePlaceholderFragmentShader",
                                                              constantValues: unlitValues)
        
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
    }
    
    func selectPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(pipelineState)
    }

    func selectUnlitPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(unlitPipelineState)
    }
}
