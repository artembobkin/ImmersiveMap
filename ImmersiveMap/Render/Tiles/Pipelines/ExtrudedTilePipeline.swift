// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

class ExtrudedTilePipeline {
    /// Opaque building geometry: solid mode draws it straight into the world pass,
    /// translucent mode into the offscreen building image.
    let pipelineState: MTLRenderPipelineState
    /// Composites the building image onto the world pass with a single fullscreen
    /// triangle using premultiplied blending.
    let compositePipelineState: MTLRenderPipelineState
    /// Depth-only replay of the same geometry from the light's camera into the
    /// shadow map. No color attachments; the fragment stage only replicates the
    /// placeIn clip discard.
    let shadowPipelineState: MTLRenderPipelineState
    /// Framebuffer-fetch path (Apple GPUs, nil elsewhere): the same building
    /// shading rendered into the world pass's second memoryless attachment,
    /// with color(0) masked off.
    let intoImagePipelineState: MTLRenderPipelineState?
    /// Framebuffer-fetch composite (Apple GPUs, nil elsewhere): reads the
    /// in-pass building attachment via [[color(1)]], blends it over color(0)
    /// with the same premultiplied factors, and writes far-plane depth to
    /// restore the pre-building depth for the scene models.
    let compositeFetchPipelineState: MTLRenderPipelineState?

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
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int = 1,
         supportsFramebufferFetch: Bool = false) {
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
        pipelineDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float

        let compositeDescriptor = MTLRenderPipelineDescriptor()
        compositeDescriptor.vertexFunction = library.makeFunction(name: "tileExtrudedCompositeVertexShader")
        compositeDescriptor.fragmentFunction = library.makeFunction(name: "tileExtrudedCompositeFragmentShader")
        compositeDescriptor.rasterSampleCount = sampleCount
        compositeDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        compositeDescriptor.depthAttachmentPixelFormat = .depth32Float
        // Premultiplied alpha: the building image color is already multiplied by the silhouette coverage.
        compositeDescriptor.colorAttachments[0].isBlendingEnabled = true
        compositeDescriptor.colorAttachments[0].rgbBlendOperation = .add
        compositeDescriptor.colorAttachments[0].alphaBlendOperation = .add
        compositeDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        compositeDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        compositeDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        compositeDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let shadowDescriptor = MTLRenderPipelineDescriptor()
        shadowDescriptor.vertexFunction = library.makeFunction(name: "tileExtrudedShadowVertexShader")
        shadowDescriptor.fragmentFunction = library.makeFunction(name: "tileExtrudedShadowFragmentShader")
        shadowDescriptor.vertexDescriptor = vertexDescriptor
        shadowDescriptor.rasterSampleCount = 1
        shadowDescriptor.depthAttachmentPixelFormat = ShadowCascadeAtlas.depthPixelFormat
        // Required for layered rendering: the vertex stage routes instances
        // to cascade slices via [[render_target_array_index]].
        shadowDescriptor.inputPrimitiveTopology = .triangle

        self.pipelineState = try! metalDevice.makeRenderPipelineState(descriptor: pipelineDescriptor)
        self.compositePipelineState = try! metalDevice.makeRenderPipelineState(descriptor: compositeDescriptor)
        self.shadowPipelineState = try! metalDevice.makeRenderPipelineState(descriptor: shadowDescriptor)

        if supportsFramebufferFetch {
            let intoImageDescriptor = MTLRenderPipelineDescriptor()
            intoImageDescriptor.vertexFunction = vertexFunction
            intoImageDescriptor.fragmentFunction = library.makeFunction(name: "tileExtrudedIntoImageFragmentShader")
            intoImageDescriptor.vertexDescriptor = vertexDescriptor
            intoImageDescriptor.rasterSampleCount = sampleCount
            intoImageDescriptor.colorAttachments[0].pixelFormat = pixelFormat
            intoImageDescriptor.colorAttachments[0].writeMask = []
            intoImageDescriptor.colorAttachments[1].pixelFormat = pixelFormat
            intoImageDescriptor.depthAttachmentPixelFormat = .depth32Float

            let compositeFetchDescriptor = MTLRenderPipelineDescriptor()
            compositeFetchDescriptor.vertexFunction = compositeDescriptor.vertexFunction
            compositeFetchDescriptor.fragmentFunction = library.makeFunction(name: "tileExtrudedCompositeFetchFragmentShader")
            compositeFetchDescriptor.rasterSampleCount = sampleCount
            compositeFetchDescriptor.colorAttachments[0].pixelFormat = pixelFormat
            compositeFetchDescriptor.colorAttachments[1].pixelFormat = pixelFormat
            compositeFetchDescriptor.colorAttachments[1].writeMask = []
            compositeFetchDescriptor.depthAttachmentPixelFormat = .depth32Float
            compositeFetchDescriptor.colorAttachments[0].isBlendingEnabled = true
            compositeFetchDescriptor.colorAttachments[0].rgbBlendOperation = .add
            compositeFetchDescriptor.colorAttachments[0].alphaBlendOperation = .add
            compositeFetchDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            compositeFetchDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            compositeFetchDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            compositeFetchDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

            self.intoImagePipelineState = try! metalDevice.makeRenderPipelineState(descriptor: intoImageDescriptor)
            self.compositeFetchPipelineState = try! metalDevice.makeRenderPipelineState(descriptor: compositeFetchDescriptor)
        } else {
            self.intoImagePipelineState = nil
            self.compositeFetchPipelineState = nil
        }
    }

    func selectPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(pipelineState)
    }

    func selectCompositePipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(compositePipelineState)
    }

    func selectShadowPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(shadowPipelineState)
    }

    /// Framebuffer-fetch path only; callers gate on the capability that
    /// created the pipeline.
    func selectIntoImagePipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(intoImagePipelineState!)
    }

    /// Framebuffer-fetch path only; callers gate on the capability that
    /// created the pipeline.
    func selectCompositeFetchPipeline(renderEncoder: MTLRenderCommandEncoder) {
        renderEncoder.setRenderPipelineState(compositeFetchPipelineState!)
    }
}
