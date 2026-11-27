// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Metal

/// What the scene models draw by (`SceneModelRenderSubsystem`): their
/// pipeline and their depth and stencil states. The model tiles draw by the
/// same surface mask state (`ModelTileRenderSubsystem`).
struct SceneModelSharedResources: SharedGPUResources {
    let pipeline: SceneModelPipeline
    /// The world-pass scene models: scene depth plus the surface mask write
    /// (see `TileSourceStencilPriority.surfaceMaskBit`).
    let surfaceMaskState: MTLDepthStencilState
    /// The four draws of a scene model that cuts into the ground (see
    /// `TileSourceStencilPriority.groundHoleBit` and SceneModel.metal).
    let groundCutStates: SceneModelGroundCutStates

    static func make(_ build: SharedGPUResourceBuild) -> SceneModelSharedResources {
        let device = build.device
        return SceneModelSharedResources(
            pipeline: SceneModelPipeline(metalDevice: device,
                                         pixelFormat: build.pixelFormat,
                                         library: build.library,
                                         sampleCount: build.sampleCount),
            surfaceMaskState: device.makeDepthStencilState(descriptor: surfaceMaskDescriptor())!,
            groundCutStates: SceneModelGroundCutStates(
                holeWrite: device.makeDepthStencilState(descriptor: groundHoleDescriptor(raises: true))!,
                holeClear: device.makeDepthStencilState(descriptor: groundHoleDescriptor(raises: false))!,
                holeTest: device.makeDepthStencilState(descriptor: groundHoleTestDescriptor())!))
    }

    // MARK: - Descriptors

    /// The world-pass scene models: scene depth, no priority test (a model
    /// belongs to no tile), and the surface mask bit raised where it lands.
    private static func surfaceMaskDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = CommonDepthStates.sceneDescriptor()
        descriptor.frontFaceStencil = TilePriorityDepthStates.surfaceMaskWriteStencil(compare: .always)
        descriptor.backFaceStencil = TilePriorityDepthStates.surfaceMaskWriteStencil(compare: .always)
        return descriptor
    }

    /// The ground hole's footprint draws (SceneModel.metal): depth neither
    /// tested nor written, the ground hole bit raised on every pixel of the
    /// flattened outline, or lowered again after the model.
    private static func groundHoleDescriptor(raises: Bool) -> MTLDepthStencilDescriptor {
        let descriptor = CommonDepthStates.disabledDescriptor()
        let stencil = MTLStencilDescriptor()
        stencil.stencilCompareFunction = .always
        stencil.stencilFailureOperation = .keep
        stencil.depthFailureOperation = .keep
        // Replace writes the reference, which is the bit, through the mask.
        // Zero clears the bit through the same mask.
        stencil.depthStencilPassOperation = raises ? .replace : .zero
        stencil.readMask = 0
        stencil.writeMask = TileSourceStencilPriority.groundHoleBit
        descriptor.frontFaceStencil = stencil
        descriptor.backFaceStencil = stencil
        return descriptor
    }

    /// The two model draws of the ground cut: scene depth, the surface mask
    /// bit raised where the model lands, and the ground hole bit tested
    /// alone, equal to the reference's bit, which the drawer sets raised for
    /// the draw inside the hole and clear for the draw outside it.
    private static func groundHoleTestDescriptor() -> MTLDepthStencilDescriptor {
        let descriptor = CommonDepthStates.sceneDescriptor()
        let stencil = TilePriorityDepthStates.surfaceMaskWriteStencil(compare: .equal)
        stencil.readMask = TileSourceStencilPriority.groundHoleBit
        descriptor.frontFaceStencil = stencil
        descriptor.backFaceStencil = stencil
        return descriptor
    }
}
