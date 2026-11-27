// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Metal

/// The tile geometry drawn straight onto the sphere in the world pass
/// (`GlobeVectorSurfaceRenderSubsystem`): the tile pipeline built for the
/// sphere.
struct GlobeVectorSurfaceSharedResources: SharedGPUResources {
    let pipeline: TilePipeline

    static func make(_ build: SharedGPUResourceBuild) -> GlobeVectorSurfaceSharedResources {
        GlobeVectorSurfaceSharedResources(pipeline: TilePipeline(metalDevice: build.device,
                                                                 pixelFormat: build.pixelFormat,
                                                                 library: build.library,
                                                                 sampleCount: build.sampleCount,
                                                                 surface: .sphere))
    }
}
