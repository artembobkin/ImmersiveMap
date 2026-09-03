// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Per-frame parameters of the flat presentation's sky; the layout mirrors
/// `FlatSky` in Atmosphere.metal (pinned by `HorizonFogUniformTests`). The
/// sky is the horizon haze's profile continued above the line, so it takes
/// the same fog uniform the ground draws with, plus the inverse
/// view-projection that turns a pixel into its view ray.
struct FlatSkyUniform {
    var inverseViewProjection: matrix_float4x4
    var fog: HorizonFogUniform

    static func make(projectionView: matrix_float4x4, fog: HorizonFogUniform) -> FlatSkyUniform {
        FlatSkyUniform(inverseViewProjection: simd_inverse(projectionView), fog: fog)
    }
}
