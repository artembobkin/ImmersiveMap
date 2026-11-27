// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Metal

/// What the road labels' draw shares (`RoadLabelDrawSubsystem`).
struct RoadLabelSharedResources: SharedGPUResources {
    /// Bound at the scene depth slot of the road labels on a frame whose
    /// depth was not kept for them: the shader skips the read when the
    /// uniform says so, but the binding itself is mandatory, and it has to
    /// be a plain `depth2d`, which the shadow map's texture array is not.
    /// A 1x1 depth texture cleared to the far plane.
    let sceneDepthFallbackTexture: MTLTexture

    static func make(_ build: SharedGPUResourceBuild) -> RoadLabelSharedResources {
        RoadLabelSharedResources(
            sceneDepthFallbackTexture: FallbackDepthTexture.make(device: build.device,
                                                                 pixelFormat: ShadowCascadeAtlas.depthPixelFormat,
                                                                 arrayLength: nil,
                                                                 label: "SceneDepthFallbackTexture"))
    }
}
