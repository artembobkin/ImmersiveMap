// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// The placement prepass pipelines (`PlacementStencilRenderSubsystem`):
/// the raster tile's grid on the plane and on the relief
/// (TileRaster.metal, tileRasterFlatVertexShader) with no fragment
/// function and every color attachment's write mask empty, so the draws
/// touch nothing but the stencil, where they write the planner's marks
/// before the ground draws.
final class PlacementStencilPipeline {
    let flatPipelineState: MTLRenderPipelineState
    /// The grid raised by the terrain bound at vertex texture 0 and buffer
    /// 9, as the raster tile's relief draw binds it.
    let flatReliefPipelineState: MTLRenderPipelineState

    init(metalDevice: MTLDevice,
         pixelFormat: MTLPixelFormat,
         library: MTLLibrary,
         sampleCount: Int = 1) {
        func state(label: String, relief: Bool) -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = label
            let values = MTLFunctionConstantValues()
            var reliefValue = relief
            values.setConstantValue(&reliefValue, type: .bool, index: 0)
            descriptor.vertexFunction = try! library.makeFunction(name: "tileRasterFlatVertexShader", constantValues: values)
            descriptor.fragmentFunction = nil
            descriptor.rasterSampleCount = sampleCount
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            descriptor.colorAttachments[0].writeMask = []
            descriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
            descriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
            return try! metalDevice.makeRenderPipelineState(descriptor: descriptor)
        }
        flatPipelineState = state(label: "PlacementStencilFlat", relief: false)
        flatReliefPipelineState = state(label: "PlacementStencilFlatRelief", relief: true)
    }
}
