// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// The fullscreen pass that paints the atmosphere around the globe's limb.
/// One pipeline state, shared by every renderer in the process.
final class AtmospherePipeline {
    let pipelineState: MTLRenderPipelineState
    /// The luminous planet body drawn before the tiles: opaque (hidden
    /// surface removal kills it under every painted slot) and its blended
    /// twin for the unfurl's fade frames. See globeBackdropVertexShader.
    let backdropPipelineState: MTLRenderPipelineState
    let backdropFadePipelineState: MTLRenderPipelineState
    /// The backdrop's coarse unit sphere: positions are unit earth
    /// directions, transformed per frame by the composed sphere matrices.
    let backdropVertexBuffer: MTLBuffer
    let backdropIndexBuffer: MTLBuffer
    let backdropIndexCount: Int
    /// The flat sky (flatSkyFragmentShader): the atmosphere's fullscreen
    /// triangle and premultiplied blend, a different fragment.
    let flatSkyPipelineState: MTLRenderPipelineState

    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int = 1) {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "AtmospherePipeline"
        descriptor.vertexFunction = library.makeFunction(name: "atmosphereVertexShader")
        descriptor.fragmentFunction = library.makeFunction(name: "atmosphereFragmentShader")
        descriptor.rasterSampleCount = sampleCount
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
        descriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
        // Premultiplied "over": the shader hands out the halo tint already
        // weighted by its coverage, and the coverage in alpha, so the halo
        // covers the limb and thins to nothing with distance. Alpha composes
        // the same way, which keeps the frame's own coverage right where
        // space is transparent.
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        // The flat sky: the same fullscreen triangle and premultiplied
        // blend, a different fragment.
        let flatSkyDescriptor = MTLRenderPipelineDescriptor()
        flatSkyDescriptor.label = "FlatSkyPipeline"
        flatSkyDescriptor.vertexFunction = descriptor.vertexFunction
        flatSkyDescriptor.fragmentFunction = library.makeFunction(name: "flatSkyFragmentShader")
        flatSkyDescriptor.rasterSampleCount = sampleCount
        flatSkyDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        flatSkyDescriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
        flatSkyDescriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
        flatSkyDescriptor.colorAttachments[0].isBlendingEnabled = true
        flatSkyDescriptor.colorAttachments[0].rgbBlendOperation = .add
        flatSkyDescriptor.colorAttachments[0].alphaBlendOperation = .add
        flatSkyDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        flatSkyDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        flatSkyDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        flatSkyDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let backdropDescriptor = MTLRenderPipelineDescriptor()
        backdropDescriptor.label = "GlobeBackdropPipeline"
        backdropDescriptor.vertexFunction = library.makeFunction(name: "globeBackdropVertexShader")
        backdropDescriptor.fragmentFunction = library.makeFunction(name: "globeBackdropFragmentShader")
        backdropDescriptor.rasterSampleCount = sampleCount
        backdropDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        backdropDescriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
        backdropDescriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8

        let backdropFadeDescriptor = MTLRenderPipelineDescriptor()
        backdropFadeDescriptor.label = "GlobeBackdropFadePipeline"
        backdropFadeDescriptor.vertexFunction = backdropDescriptor.vertexFunction
        backdropFadeDescriptor.fragmentFunction = library.makeFunction(name: "globeBackdropFadeFragmentShader")
        backdropFadeDescriptor.rasterSampleCount = sampleCount
        backdropFadeDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        backdropFadeDescriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
        backdropFadeDescriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
        backdropFadeDescriptor.colorAttachments[0].isBlendingEnabled = true
        backdropFadeDescriptor.colorAttachments[0].rgbBlendOperation = .add
        backdropFadeDescriptor.colorAttachments[0].alphaBlendOperation = .add
        backdropFadeDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        backdropFadeDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        backdropFadeDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        backdropFadeDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let mesh = Self.makeUnitSphereMesh()
        guard let vertexBuffer = metalDevice.makeBuffer(bytes: mesh.positions,
                                                        length: mesh.positions.count * MemoryLayout<Float>.stride,
                                                        options: .storageModeShared),
              let indexBuffer = metalDevice.makeBuffer(bytes: mesh.indices,
                                                       length: mesh.indices.count * MemoryLayout<UInt16>.stride,
                                                       options: .storageModeShared) else {
            fatalError("Failed to allocate the globe backdrop mesh")
        }
        vertexBuffer.label = "GlobeBackdropVertices"
        indexBuffer.label = "GlobeBackdropIndices"
        backdropVertexBuffer = vertexBuffer
        backdropIndexBuffer = indexBuffer
        backdropIndexCount = mesh.indices.count

        do {
            pipelineState = try metalDevice.makeRenderPipelineState(descriptor: descriptor)
            flatSkyPipelineState = try metalDevice.makeRenderPipelineState(descriptor: flatSkyDescriptor)
            backdropPipelineState = try metalDevice.makeRenderPipelineState(descriptor: backdropDescriptor)
            backdropFadePipelineState = try metalDevice.makeRenderPipelineState(descriptor: backdropFadeDescriptor)
        } catch {
            fatalError("Failed to create atmosphere pipeline: \(error)")
        }
    }

    /// A coarse lat-long unit sphere (positions as packed float3 unit
    /// directions). Coarse on purpose: the silhouette's slight polygonality
    /// hides under the atmosphere's rim glow, and the body's job is
    /// coverage, not shape. Drawn without culling: the far hemisphere lands
    /// at the same far-band depth and hidden surface removal keeps one.
    private static func makeUnitSphereMesh() -> (positions: [Float], indices: [UInt16]) {
        let rings = 24
        let segments = 48
        var positions: [Float] = []
        positions.reserveCapacity((rings + 1) * (segments + 1) * 3)
        for ring in 0...rings {
            let theta = Float(ring) / Float(rings) * .pi
            let z = cos(theta)
            let ringRadius = sin(theta)
            for segment in 0...segments {
                let phi = Float(segment) / Float(segments) * 2 * .pi
                positions.append(ringRadius * cos(phi))
                positions.append(ringRadius * sin(phi))
                positions.append(z)
            }
        }
        var indices: [UInt16] = []
        indices.reserveCapacity(rings * segments * 6)
        let stride = segments + 1
        for ring in 0..<rings {
            for segment in 0..<segments {
                let a = UInt16(ring * stride + segment)
                let b = UInt16(ring * stride + segment + 1)
                let c = UInt16((ring + 1) * stride + segment)
                let d = UInt16((ring + 1) * stride + segment + 1)
                indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }
        return (positions, indices)
    }
}

/// Draws the atmosphere: one fullscreen triangle whose fragment stage
/// resolves, per pixel, how far the view ray passes from the globe's limb
/// and paints the scattered light there. Stateless beyond the pipeline;
/// every frame's parameters arrive as one uniform.
final class AtmosphereRenderer {
    private let pipeline: AtmospherePipeline

    init(pipeline: AtmospherePipeline) {
        self.pipeline = pipeline
    }

    func draw(renderEncoder: MTLRenderCommandEncoder,
              uniform: AtmosphereUniform) {
        var uniformValue = uniform
        renderEncoder.setRenderPipelineState(pipeline.pipelineState)
        renderEncoder.setCullMode(.none)
        renderEncoder.setFragmentBytes(&uniformValue,
                                       length: MemoryLayout<AtmosphereUniform>.stride,
                                       index: 0)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// The flat sky above the horizon (and in any coverage hole), after the
    /// ground, under the sky's far-plane depth test.
    func drawFlatSky(renderEncoder: MTLRenderCommandEncoder,
                     uniform: FlatSkyUniform) {
        var uniformValue = uniform
        renderEncoder.setRenderPipelineState(pipeline.flatSkyPipelineState)
        renderEncoder.setCullMode(.none)
        renderEncoder.setFragmentBytes(&uniformValue,
                                       length: MemoryLayout<FlatSkyUniform>.stride,
                                       index: 0)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }

    /// The luminous planet body before the tiles; opaque on the resting
    /// sphere, blended while the unfurl fades it out.
    func drawBackdrop(renderEncoder: MTLRenderCommandEncoder,
                      uniform: GlobeBackdropUniform) {
        var uniformValue = uniform
        renderEncoder.setRenderPipelineState(uniform.fade >= 1.0
                                             ? pipeline.backdropPipelineState
                                             : pipeline.backdropFadePipelineState)
        renderEncoder.setCullMode(.none)
        renderEncoder.setVertexBuffer(pipeline.backdropVertexBuffer, offset: 0, index: 0)
        renderEncoder.setVertexBytes(&uniformValue, length: MemoryLayout<GlobeBackdropUniform>.stride, index: 1)
        renderEncoder.setFragmentBytes(&uniformValue, length: MemoryLayout<GlobeBackdropUniform>.stride, index: 1)
        renderEncoder.drawIndexedPrimitives(type: .triangle,
                                            indexCount: pipeline.backdropIndexCount,
                                            indexType: .uint16,
                                            indexBuffer: pipeline.backdropIndexBuffer,
                                            indexBufferOffset: 0)
    }
}
