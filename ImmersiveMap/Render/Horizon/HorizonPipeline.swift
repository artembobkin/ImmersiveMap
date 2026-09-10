// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// The pass that paints the air around the surface's edge: the globe's
/// atmosphere and limb feather, the flat map's fog. One shading function
/// behind a side constant, two depth tests around it (see
/// `HorizonRenderSubsystem`), one geometry: the band (`HorizonBandMesh`).
final class HorizonPipeline {
    let skyPipelineState: MTLRenderPipelineState
    let groundPipelineState: MTLRenderPipelineState
    let bandMesh: HorizonBandMesh

    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int = 1) {
        func makeFragment(name: String, groundSide: Bool) -> MTLFunction {
            let constants = MTLFunctionConstantValues()
            var value = groundSide
            constants.setConstantValue(&value, type: .bool, index: 0)
            do {
                return try library.makeFunction(name: name, constantValues: constants)
            } catch {
                fatalError("Failed to specialize the horizon fragment shader: \(error)")
            }
        }
        // Mirrors HorizonBandMesh.Vertex: two floats.
        let bandVertexDescriptor = MTLVertexDescriptor()
        bandVertexDescriptor.attributes[0].format = .float
        bandVertexDescriptor.attributes[0].offset = 0
        bandVertexDescriptor.attributes[0].bufferIndex = 0
        bandVertexDescriptor.attributes[1].format = .float
        bandVertexDescriptor.attributes[1].offset = MemoryLayout<Float>.stride
        bandVertexDescriptor.attributes[1].bufferIndex = 0
        bandVertexDescriptor.layouts[0].stride = MemoryLayout<HorizonBandMesh.Vertex>.stride
        bandVertexDescriptor.layouts[0].stepFunction = .perVertex
        func makeState(groundSide: Bool) -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = groundSide ? "HorizonGroundPipeline" : "HorizonSkyPipeline"
            descriptor.vertexFunction = library.makeFunction(name: "horizonBandVertexShader")
            descriptor.fragmentFunction = makeFragment(name: "horizonBandFragmentShader", groundSide: groundSide)
            descriptor.vertexDescriptor = bandVertexDescriptor
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
            do {
                return try metalDevice.makeArchivedRenderPipelineState(descriptor: descriptor)
            } catch {
                fatalError("Failed to create the horizon pipeline: \(error)")
            }
        }
        skyPipelineState = makeState(groundSide: false)
        groundPipelineState = makeState(groundSide: true)
        guard let bandMesh = HorizonBandMesh(metalDevice: metalDevice) else {
            fatalError("Failed to allocate the horizon band mesh")
        }
        self.bandMesh = bandMesh
    }

    func pipelineState(groundSide: Bool) -> MTLRenderPipelineState {
        groundSide ? groundPipelineState : skyPipelineState
    }
}

/// Draws one side of the horizon layer: the band at the far plane, whose
/// vertices are directions and whose fragments resolve the angle above or
/// below the edge from them. Stateless beyond the pipeline; every frame's
/// parameters arrive as one uniform.
final class HorizonRenderer {
    private let pipeline: HorizonPipeline

    init(pipeline: HorizonPipeline) {
        self.pipeline = pipeline
    }

    func draw(renderEncoder: MTLRenderCommandEncoder,
              uniform: HorizonUniform,
              groundSide: Bool) {
        var uniformValue = uniform
        renderEncoder.setRenderPipelineState(pipeline.pipelineState(groundSide: groundSide))
        renderEncoder.setCullMode(.none)
        renderEncoder.setFragmentBytes(&uniformValue,
                                       length: MemoryLayout<HorizonUniform>.stride,
                                       index: 0)
        let mesh = pipeline.bandMesh
        renderEncoder.setVertexBuffer(mesh.vertexBuffer, offset: 0, index: 0)
        renderEncoder.setVertexBytes(&uniformValue,
                                     length: MemoryLayout<HorizonUniform>.stride,
                                     index: 1)
        renderEncoder.drawIndexedPrimitives(type: .triangle,
                                            indexCount: mesh.indexCount,
                                            indexType: .uint16,
                                            indexBuffer: mesh.indexBuffer,
                                            indexBufferOffset: 0)
    }
}
