// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Metal

/// The flat map's vector ground (`FlatMapSurfaceRenderSubsystem`): the tile
/// pipeline of the plane, which reads the ground shadow mask. A set of its
/// own, since the sphere builds the same pipeline type its own way
/// (`GlobeVectorSurfaceSharedResources`).
struct FlatGroundSharedResources: SharedGPUResources {
    let pipeline: TilePipeline

    static func make(_ build: SharedGPUResourceBuild) -> FlatGroundSharedResources {
        FlatGroundSharedResources(pipeline: TilePipeline(metalDevice: build.device,
                                                         pixelFormat: build.pixelFormat,
                                                         library: build.library,
                                                         sampleCount: build.sampleCount,
                                                         readsGroundShadowMask: true))
    }
}
