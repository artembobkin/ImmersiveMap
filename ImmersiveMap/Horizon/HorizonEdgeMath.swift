// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The visible edge of the surface, as the camera sees it: the limb of the
/// sphere the surface currently lives on, or the plane's horizon. CPU
/// mirror of `horizonAngleAboveEdge` in Horizon.metal, term for term.
///
/// The unroll keeps the surface a sphere of curvature `(1 - t) / R` tangent
/// to the view centre (`GlobeUnroll.h`), centred at `(0, 0, -1 / curvature)`;
/// the plane is curvature zero. Everything here is written in the curvature
/// so that the plane is the limit of the formulas and never a branch:
///
/// - the eye's local vertical is `normalize(curvature * eye + (0, 0, 1))`,
///   which is `(0, 0, 1)` on the plane;
/// - the limb sits below that vertical by `atan(limbDistance * curvature)`,
///   where `(limbDistance * curvature)^2 = curvature^2 |eye|^2 + 2 curvature
///   eye.z` (the eye's distance to the limb point, without ever forming the
///   sphere's huge centre coordinate), which is zero on the plane.
///
/// A view direction's angle above the edge is then its elevation above the
/// vertical's horizontal plane plus the limb's depression: on the resting
/// sphere the classic `acos(dir . toCenter) - asin(R / d)`, on the plane
/// `asin(direction.z)`.
enum HorizonEdgeMath {
    struct Edge: Equatable {
        /// The eye's local vertical, a unit vector.
        let up: SIMD3<Float>
        /// How far below the local horizontal the edge lies, radians.
        let depression: Float
        /// Distance from the eye to the limb point; infinite on the plane.
        let limbDistance: Float
    }

    static func edge(eye: SIMD3<Float>, curvature: Float) -> Edge {
        let c = max(curvature, 0)
        let up = simd_normalize(c * eye + SIMD3<Float>(0, 0, 1))
        let scaledLimbDistance = max(c * c * simd_length_squared(eye) + 2 * c * eye.z, 0).squareRoot()
        return Edge(up: up,
                    depression: atan(scaledLimbDistance),
                    limbDistance: c > 0 ? scaledLimbDistance / c : .infinity)
    }

    /// Signed angle of a unit view direction above the edge: positive looks
    /// past the surface into the sky, negative looks at the surface.
    static func angleAboveEdge(direction: SIMD3<Float>, edge: Edge) -> Float {
        asin(simd_clamp(simd_dot(direction, edge.up), -1, 1)) + edge.depression
    }

    /// The four viewport corner rays, from the far-plane corners back to the
    /// eye. A degenerate projection yields the vertical instead of a division
    /// by zero.
    static func cornerDirections(inverseProjectionView: matrix_float4x4,
                                 eye: SIMD3<Float>) -> [SIMD3<Float>] {
        var directions: [SIMD3<Float>] = []
        for cornerX in [Float(-1), 1] {
            for cornerY in [Float(-1), 1] {
                let farClip = inverseProjectionView * SIMD4<Float>(cornerX, cornerY, 1, 1)
                guard abs(farClip.w) > 1e-9 else {
                    directions.append(SIMD3<Float>(0, 0, 1))
                    continue
                }
                let farPoint = SIMD3<Float>(farClip.x, farClip.y, farClip.z) / farClip.w
                directions.append(simd_normalize(farPoint - eye))
            }
        }
        return directions
    }

    /// True when some pixel of the frame looks within `reachBelow` radians of
    /// the edge or above it, which is when the horizon layer has anything to
    /// paint. The set of directions farther below the edge than the reach is
    /// a cone about the nadir, convex on screen, so the frame lies entirely
    /// inside it if and only if its four corners do.
    static func isEdgeWithinReach(edge: Edge,
                                  reachBelow: Float,
                                  inverseProjectionView: matrix_float4x4,
                                  eye: SIMD3<Float>) -> Bool {
        cornerDirections(inverseProjectionView: inverseProjectionView, eye: eye)
            .contains { angleAboveEdge(direction: $0, edge: edge) >= -reachBelow }
    }
}
