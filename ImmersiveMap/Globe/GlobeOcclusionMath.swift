// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The sphere as an analytic occluder: the CPU mirror of
/// `globeOcclusionClearance` in GlobeOcclusion.h, which the globe surface
/// shaders hand to the rasterizer as a clip distance. Kept bit-compatible
/// with the shader so tests can state, on the CPU, what the GPU clips.
enum GlobeOcclusionMath {
    /// The sphere is shrunk by this fraction of its radius before the test:
    /// the near side's vertices sit exactly on the sphere at t = 0, and the
    /// chords between them sag below it, so without a margin the clearance of
    /// the whole visible surface would be zero plus float noise.
    static let radiusMargin: Float = 1.0e-4

    /// How far the segment from `eye` to `position` passes clear of the sphere
    /// of `radius` centred at `(0, 0, -radius)`, in world units: positive when
    /// the eye sees the point (it lies in front of the planet, or the segment
    /// misses the planet), negative when the planet stands in the way.
    static func clearance(position: SIMD3<Float>, eye: SIMD3<Float>, radius: Float) -> Float {
        let occluderRadius = max(radius, 1e-6) * (1.0 - radiusMargin)
        let globeCenter = SIMD3<Float>(0.0, 0.0, -radius)
        let centerToEye = eye - globeCenter
        let toPosition = position - eye
        let lengthSquared = simd_dot(toPosition, toPosition)
        if lengthSquared <= 0.0 {
            return simd_length(centerToEye) - occluderRadius
        }
        let closestFraction = -simd_dot(centerToEye, toPosition) / lengthSquared
        if closestFraction <= 0.0 {
            return simd_length(centerToEye) - occluderRadius
        }
        if closestFraction >= 1.0 {
            return simd_length(position - globeCenter) - occluderRadius
        }
        let closest = centerToEye + toPosition * closestFraction
        return simd_length(closest) - occluderRadius
    }
}
