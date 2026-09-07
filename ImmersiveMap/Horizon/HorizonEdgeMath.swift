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

    /// The view ray through a point of the viewport, from its far-plane
    /// point back to the eye. A degenerate projection yields the vertical
    /// instead of a division by zero.
    static func viewDirection(ndc: SIMD2<Float>,
                              inverseProjectionView: matrix_float4x4,
                              eye: SIMD3<Float>) -> SIMD3<Float> {
        let farClip = inverseProjectionView * SIMD4<Float>(ndc.x, ndc.y, 1, 1)
        guard abs(farClip.w) > 1e-9 else {
            return SIMD3<Float>(0, 0, 1)
        }
        let farPoint = SIMD3<Float>(farClip.x, farClip.y, farClip.z) / farClip.w
        return simd_normalize(farPoint - eye)
    }

    /// The four viewport corner rays.
    static func cornerDirections(inverseProjectionView: matrix_float4x4,
                                 eye: SIMD3<Float>) -> [SIMD3<Float>] {
        var directions: [SIMD3<Float>] = []
        for cornerX in [Float(-1), 1] {
            for cornerY in [Float(-1), 1] {
                directions.append(viewDirection(ndc: SIMD2<Float>(cornerX, cornerY),
                                                inverseProjectionView: inverseProjectionView,
                                                eye: eye))
            }
        }
        return directions
    }

    /// How far below the edge the ground lies at a given multiple of the
    /// camera distance, on the plane. The camera looks at the ground along
    /// the centre ray, `cosPitch` under the local horizontal, so its height
    /// over the plane is `cosPitch` camera distances and the ground at `k`
    /// camera distances of slant range sits `asin(cosPitch / k)` below the
    /// line; nearer than the eye's height it is the nadir. This is what lets
    /// a haze stated in camera distances stay a plain angle profile in the
    /// shader.
    static func depression(atCameraDistances k: Float, cosPitch: Float) -> Float {
        asin(min(max(cosPitch, 0) / max(k, 1e-6), 1))
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
