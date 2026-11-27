// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Metal

/// What the placement prepass draws by (`PlacementStencilRenderSubsystem`):
/// its pipeline and the states that write the planner's marks into the
/// tile-priority stencil (`TileSourceStencilPriority`).
struct PlacementStencilSharedResources: SharedGPUResources {
    let pipeline: PlacementStencilPipeline
    /// The prepass on the plane and the sphere: the depth neither tested
    /// nor written, the source's zoom written into the priority bits.
    let stencilWrite: MTLDepthStencilState
    /// The prepass on the relief: first the ground's depth, every point
    /// once, the stencil untouched, then the marks tested against that
    /// depth and writing none.
    let depthWrite: MTLDepthStencilState
    let stencilReliefWrite: MTLDepthStencilState
    /// The prepass's depth reset: the depth written whatever is there, the
    /// stencil untouched.
    let depthReset: MTLDepthStencilState

    static func make(_ build: SharedGPUResourceBuild) -> PlacementStencilSharedResources {
        let device = build.device
        return PlacementStencilSharedResources(
            pipeline: PlacementStencilPipeline(metalDevice: device,
                                               pixelFormat: build.pixelFormat,
                                               library: build.library,
                                               sampleCount: build.sampleCount),
            stencilWrite: device.makeDepthStencilState(descriptor: stencilWriteDescriptor())!,
            depthWrite: device.makeDepthStencilState(descriptor: depthWriteDescriptor())!,
            stencilReliefWrite: device.makeDepthStencilState(descriptor: stencilReliefWriteDescriptor())!,
            depthReset: device.makeDepthStencilState(descriptor: depthResetDescriptor())!)
    }

    // MARK: - Descriptors

    /// The placement prepass on the plane and the sphere: the depth always
    /// passes and is never written, so a placement's mark lands on every
    /// pixel of its square, through the priority bits alone
    /// (`TileSourceStencilPriority`).
    private static func stencilWriteDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = CommonDepthStates.disabledDescriptor()
        descriptor.frontFaceStencil = markStencil()
        descriptor.backFaceStencil = markStencil()
        return descriptor
    }

    /// The relief's first prepass: the ground's depth, every point of it
    /// once, the nearer of two surfaces kept, the stencil untouched.
    private static func depthWriteDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .lessEqual
        descriptor.isDepthWriteEnabled = true
        return descriptor
    }

    /// The relief's marks: a placement's mark lands where its ground is
    /// the one in front, at or before the ground's depth, and the depth
    /// is left as it is.
    private static func stencilReliefWriteDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .lessEqual
        descriptor.isDepthWriteEnabled = false
        descriptor.frontFaceStencil = markStencil()
        descriptor.backFaceStencil = markStencil()
        return descriptor
    }

    /// The relief's depth reset: the far plane written over every pixel,
    /// the stencil untouched, so the ground passes meet the cleared depth.
    private static func depthResetDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.depthCompareFunction = .always
        descriptor.isDepthWriteEnabled = true
        return descriptor
    }

    private static func markStencil() -> MTLStencilDescriptor {
        let stencil = MTLStencilDescriptor()
        stencil.stencilCompareFunction = .always
        stencil.stencilFailureOperation = .keep
        stencil.depthFailureOperation = .keep
        stencil.depthStencilPassOperation = .replace
        stencil.readMask = 0
        stencil.writeMask = TileSourceStencilPriority.priorityMask
        return stencil
    }
}
