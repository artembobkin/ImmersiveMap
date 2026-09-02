// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Whether any sky is visible around the resting sphere: the space décor
/// (the stars and the atmosphere) is skipped for the frame when the planet
/// fills the whole viewport, which is every region zoom. The sphere's
/// screen projection is convex, so the frame shows sky if and only if at
/// least one of its corners does; four ray-sphere tests decide the frame.
///
/// Valid on the resting sphere only (transition 0): mid-morph the surface
/// leaves the sphere the test intersects, and the décor is drawn as before
/// (it fades with the transition on its own).
enum GlobeSkyVisibilityMath {
    /// True when at least one viewport corner ray misses the planet (or the
    /// planet is behind the eye there): some sky is on screen.
    static func isSkyVisible(inverseProjectionView: matrix_float4x4,
                             eye: SIMD3<Float>,
                             radius: Float) -> Bool {
        let center = SIMD3<Float>(0, 0, -radius)
        for cornerX in [Float(-1), 1] {
            for cornerY in [Float(-1), 1] {
                let farClip = inverseProjectionView * SIMD4<Float>(cornerX, cornerY, 1, 1)
                guard abs(farClip.w) > 1e-9 else { return true }
                let farPoint = SIMD3<Float>(farClip.x, farClip.y, farClip.z) / farClip.w
                let direction = simd_normalize(farPoint - eye)
                let toCenter = center - eye
                let along = simd_dot(toCenter, direction)
                if along <= 0 {
                    // The planet is behind the eye along this corner: sky.
                    return true
                }
                let perpendicularSquared = simd_length_squared(toCenter) - along * along
                if perpendicularSquared > radius * radius {
                    // The corner ray misses the planet: sky.
                    return true
                }
            }
        }
        return false
    }
}
