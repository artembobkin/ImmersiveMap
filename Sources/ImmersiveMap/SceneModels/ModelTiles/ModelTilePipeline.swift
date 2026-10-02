// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// The pipelines the models of the model tiles draw with (ModelTile.metal):
/// the opaque world-pass pipeline, its variant that drops the fragments
/// below the ground and the stencil-only footprint pipeline, the two the
/// ground cut adds, and the shadow caster pipeline. The same four the scene
/// models have, over the vertex a model tile carries, in the tile's space.
final class ModelTilePipeline {
    let pipelineState: MTLRenderPipelineState
    /// The opaque pipeline with `kModelTileClipsBelowGround` on: the second
    /// draw of a model that cuts into the ground, outside its ground hole.
    let belowGroundClippedPipelineState: MTLRenderPipelineState
    /// The model flattened onto the ground plane, writing neither colour
    /// nor depth: the draw that raises or lowers the ground hole bit.
    let groundFootprintPipelineState: MTLRenderPipelineState
    /// Depth-only replay into the shadow map.
    let shadowPipelineState: MTLRenderPipelineState
    let baseColorSampler: MTLSamplerState

    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int = 1) {
        // The vertex of a model tile, as the baker wrote it.
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .char3Normalized
        vertexDescriptor.attributes[1].offset = ModelTileContents.normalOffset
        vertexDescriptor.attributes[1].bufferIndex = 0
        vertexDescriptor.attributes[2].format = .uchar
        vertexDescriptor.attributes[2].offset = ModelTileContents.layerOffset
        vertexDescriptor.attributes[2].bufferIndex = 0
        vertexDescriptor.attributes[3].format = .ushort2Normalized
        vertexDescriptor.attributes[3].offset = ModelTileContents.textureCoordinateOffset
        vertexDescriptor.attributes[3].bufferIndex = 0
        vertexDescriptor.layouts[0].stride = ModelTileContents.vertexStride
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        let vertexFunction = library.makeFunction(name: "modelTileVertexShader")

        func makeFragmentFunction(clipsBelowGround: Bool) -> MTLFunction {
            let constants = MTLFunctionConstantValues()
            var clips = clipsBelowGround
            constants.setConstantValue(&clips, type: .bool, index: 0)
            return try! library.makeFunction(name: "modelTileFragmentShader", constantValues: constants)
        }

        func makeMainDescriptor(clipsBelowGround: Bool) -> MTLRenderPipelineDescriptor {
            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = vertexFunction
            pipelineDescriptor.fragmentFunction = makeFragmentFunction(clipsBelowGround: clipsBelowGround)
            pipelineDescriptor.vertexDescriptor = vertexDescriptor
            pipelineDescriptor.rasterSampleCount = sampleCount
            pipelineDescriptor.colorAttachments[0].pixelFormat = pixelFormat
            pipelineDescriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
            pipelineDescriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
            return pipelineDescriptor
        }

        self.pipelineState = try! metalDevice.makeRenderPipelineState(
            descriptor: makeMainDescriptor(clipsBelowGround: false))
        self.belowGroundClippedPipelineState = try! metalDevice.makeRenderPipelineState(
            descriptor: makeMainDescriptor(clipsBelowGround: true))

        // Stencil only: the colour attachment is the world pass's, masked
        // off, and no fragment function runs.
        let footprintDescriptor = MTLRenderPipelineDescriptor()
        footprintDescriptor.vertexFunction = library.makeFunction(name: "modelTileGroundFootprintVertexShader")
        footprintDescriptor.fragmentFunction = nil
        footprintDescriptor.vertexDescriptor = vertexDescriptor
        footprintDescriptor.rasterSampleCount = sampleCount
        footprintDescriptor.colorAttachments[0].pixelFormat = pixelFormat
        footprintDescriptor.colorAttachments[0].writeMask = []
        footprintDescriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
        footprintDescriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
        self.groundFootprintPipelineState = try! metalDevice.makeRenderPipelineState(descriptor: footprintDescriptor)

        let shadowDescriptor = MTLRenderPipelineDescriptor()
        shadowDescriptor.vertexFunction = library.makeFunction(name: "modelTileShadowVertexShader")
        shadowDescriptor.fragmentFunction = nil
        shadowDescriptor.vertexDescriptor = vertexDescriptor
        shadowDescriptor.rasterSampleCount = 1
        shadowDescriptor.depthAttachmentPixelFormat = ShadowCascadeAtlas.depthPixelFormat
        shadowDescriptor.inputPrimitiveTopology = .triangle
        self.shadowPipelineState = try! metalDevice.makeRenderPipelineState(descriptor: shadowDescriptor)

        // The array has no repeat: a model tile's texture coordinates stay
        // inside the unit square, so the edge is clamped and a layer never
        // wraps into its own far side.
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        // A facade is seen at a slant more often than head on.
        samplerDescriptor.maxAnisotropy = 4
        self.baseColorSampler = metalDevice.makeSamplerState(descriptor: samplerDescriptor)!
    }
}
