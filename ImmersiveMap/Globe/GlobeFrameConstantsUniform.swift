// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Per-frame derivatives of the globe uniform, computed once on the CPU
/// instead of once per vertex; the layout mirrors `GlobeFrameConstants` in
/// RenderUniforms.h (pinned by `GlobeSphereVertexPathTests`).
///
/// The hot globe vertex stages take everything a frame can precompute: the
/// pan rotation, the composed sphere matrices (`sphereClip` carries a unit
/// earth direction straight to clip space, `sphereWorld` to the world-space
/// sphere position), the flat morph target's map size and Mercator pan, and
/// the unroll curvature. The expressions copy
/// `GeoScreenProjectionMath.FrameConstants`, the CPU mirror of the same
/// shader math, term for term; `rotation` keeps the row-vector column
/// layout legacy shaders multiply with (`v * M`), while the composed
/// matrices are column-vector (`M * v`) like the camera matrix.
struct GlobeFrameConstantsUniform {
    var rotation: matrix_float4x4
    var sphereClip: matrix_float4x4
    var sphereWorld: matrix_float4x4
    var mapSize: Float
    var panMercatorY: Float
    var panLatitude: Float
    var panLongitude: Float
    var curvature: Float
    var _padding: SIMD3<Float> = .zero

    static func make(globe: GlobeUniform, cameraMatrix: matrix_float4x4) -> GlobeFrameConstantsUniform {
        let panLatitude = globe.panY * Float(ImmersiveMapProjection.maxMercatorLatitude)
        let panLongitude = globe.panX * Float.pi
        // Mirror of globeTransitionMapSize: the flat morph target grows from
        // cos(center latitude) up to the full Mercator size.
        let distortion = cos(panLatitude)
        let mapSizeScale = (1.0 - globe.transition) * distortion + globe.transition
        let mapSize = 2.0 * Float.pi * globe.radius * mapSizeScale
        let panMercatorY = Float(ImmersiveMapProjection.yMercatorNormalized(latitude: Double(panLatitude)))
        let rotation = Self.rotationMatrix(panLatitude: panLatitude, panLongitude: panLongitude)

        // sphereWorld = translate(0, 0, -R) * rotationT * scale(R): a unit
        // earth direction to its world-space sphere position, in the
        // column-vector convention.
        let radius = globe.radius
        var sphereWorld = simd_mul(simd_transpose(rotation), matrix_float4x4(diagonal: SIMD4<Float>(radius, radius, radius, 1)))
        sphereWorld.columns.3.z -= radius
        let sphereClip = simd_mul(cameraMatrix, sphereWorld)
        let curvature = (1.0 - globe.transition) / max(radius, 1e-6)

        return GlobeFrameConstantsUniform(rotation: rotation,
                                          sphereClip: sphereClip,
                                          sphereWorld: sphereWorld,
                                          mapSize: mapSize,
                                          panMercatorY: panMercatorY,
                                          panLatitude: panLatitude,
                                          panLongitude: panLongitude,
                                          curvature: curvature)
    }

    /// The pan rotation exactly as `globeVisibilityRotationMatrix` builds it
    /// on the GPU: column constructor arguments in the row-vector layout the
    /// shaders consume with `v * M`.
    static func rotationMatrix(panLatitude: Float,
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
