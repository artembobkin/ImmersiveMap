// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Metal

/// What the horizon layer draws by (`HorizonRenderSubsystem`): its pipeline
/// and the depth state of its ground side. Its sky side draws by the
/// common read-only scene depth (`CommonDepthStates.sceneReadOnly`).
struct HorizonSharedResources: SharedGPUResources {
    /// The air around the surface's edge, on both surfaces.
    let pipeline: HorizonPipeline
    /// The ground side: the far-plane fragment passes only where something
    /// wrote a nearer depth (the ground's rank band), never written, and
    /// not where a building or a model raised the surface mask bit, so the
    /// haze reaches the painted ground alone and the sky side keeps the
    /// rest.
    let groundDepthState: MTLDepthStencilState

    static func make(_ build: SharedGPUResourceBuild) -> HorizonSharedResources {
        HorizonSharedResources(
            pipeline: HorizonPipeline(metalDevice: build.device,
                                      pixelFormat: build.pixelFormat,
                                      library: build.library,
                                      sampleCount: build.sampleCount),
            groundDepthState: build.device.makeDepthStencilState(descriptor: groundDepthDescriptor())!)
    }

    /// A far-plane fragment (z = 1) passes the greater test exactly where a
    /// nearer depth was written, which is every painted pixel, and fails on
    /// the cleared depth of the sky.
    private static func groundDepthDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .greater
        descriptor.isDepthWriteEnabled = false
        // And not where a standing surface raised the mask bit: the haze is
        // the ground's, and a wall crossing the horizon row keeps its own
        // colour. Reference 0 through a mask of the bit alone.
        let stencil = MTLStencilDescriptor()
        stencil.stencilCompareFunction = .equal
        stencil.stencilFailureOperation = .keep
        stencil.depthFailureOperation = .keep
        stencil.depthStencilPassOperation = .keep
        stencil.readMask = TileSourceStencilPriority.surfaceMaskBit
        stencil.writeMask = 0
        descriptor.frontFaceStencil = stencil
        descriptor.backFaceStencil = stencil
        return descriptor
    }
}
