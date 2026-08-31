// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Per-frame derivatives of the globe uniform, computed once on the CPU
/// instead of once per vertex; the layout mirrors `GlobeFrameConstants` in
/// RenderUniforms.h (pinned by `GlobeSphereVertexPathTests`).
///
/// The hot globe vertex stages used to rebuild the pan rotation matrix, the
/// flat morph target's map size and the Mercator pan for every vertex, all
/// pure functions of the frame's `GlobeUniform`. The expressions here copy
/// `GeoScreenProjectionMath.FrameConstants`, the CPU mirror of the same
/// shader math, term for term; the matrix keeps the row-vector column
/// layout the shaders multiply with (the mirror transposes it for Swift's
/// column-vector convention, the shaders must not).
struct GlobeFrameConstantsUniform {
    var rotation: matrix_float4x4
    var mapSize: Float
    var panMercatorY: Float
    var panLatitude: Float
    var panLongitude: Float

    static func make(globe: GlobeUniform) -> GlobeFrameConstantsUniform {
        let panLatitude = globe.panY * Float(ImmersiveMapProjection.maxMercatorLatitude)
        let panLongitude = globe.panX * Float.pi
        // Mirror of globeTransitionMapSize: the flat morph target grows from
        // cos(center latitude) up to the full Mercator size.
        let distortion = cos(panLatitude)
        let mapSizeScale = (1.0 - globe.transition) * distortion + globe.transition
        let mapSize = 2.0 * Float.pi * globe.radius * mapSizeScale
        let panMercatorY = Float(ImmersiveMapProjection.yMercatorNormalized(latitude: Double(panLatitude)))
        return GlobeFrameConstantsUniform(rotation: Self.rotationMatrix(panLatitude: panLatitude,
                                                                        panLongitude: panLongitude),
                                          mapSize: mapSize,
                                          panMercatorY: panMercatorY,
                                          panLatitude: panLatitude,
                                          panLongitude: panLongitude)
    }

    /// The pan rotation exactly as `globeVisibilityRotationMatrix` builds it
    /// on the GPU: column constructor arguments in the row-vector layout the
    /// shaders consume with `v * M`.
    private static func rotationMatrix(panLatitude: Float,
                                       panLongitude: Float) -> matrix_float4x4 {
        let cx = cos(-panLatitude)
        let sx = sin(-panLatitude)
        let cy = cos(-panLongitude)
        let sy = sin(-panLongitude)
        return matrix_float4x4(columns: (
            SIMD4<Float>(cy, 0, -sy, 0),
            SIMD4<Float>(sy * sx, cx, cy * sx, 0),
            SIMD4<Float>(sy * cx, -sx, cy * cx, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }
}
