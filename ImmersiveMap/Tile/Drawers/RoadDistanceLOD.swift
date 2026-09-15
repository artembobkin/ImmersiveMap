// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Distance LOD for the roads themselves: the roads fade out with the
/// ground distance from the look-at point and are gone beyond an outer
/// radius. In the far range of a tilted view the streets are lines under
/// a pixel wide seen at a grazing angle, and the network shimmers with
/// every camera step. The fade is per vertex in the tile shader
/// (`RoadDistanceFadeUniform`): the alpha steps smoothly from 1 at
/// `fadeStart` to 0 at `fadeEnd`, both radii around the look-at point on
/// the ground plane, and a clip distance drops the geometry beyond the
/// outer radius, so the boundary is one circle on the ground about the
/// point the camera looks at, the same for every tile whatever its zoom,
/// and it follows the camera smoothly. On top of that the drawer skips the
/// road draws of a tile whose nearest point lies beyond the outer radius
/// (no vertices, no binds); the clip makes the skip invisible.
///
/// Both radii are multiples of the camera distance (eye to look-at), so
/// the ring scales with the zoom like the ground coverage does, with a
/// floor in metres: close up the camera distance is a street's width and
/// the ring would end a block away, so the outer radius never falls below
/// `minimumFadeEndMeters` on the ground (the inner keeps its share of it).
/// The debug panel's three knobs override the defaults per frame.
enum RoadDistanceLOD {
    /// The radius, in camera distances, at which the roads start to fade.
    static let fadeStartCameraDistances: Float = 0.5
    /// The radius, in camera distances, at which the roads are gone.
    static let fadeEndCameraDistances: Float = 2.7
    /// The knobs' travel: from roads on the look-at tile only up to the
    /// coverage's whole reach.
    static let cameraDistancesRange: ClosedRange<Float> = 0.5 ... 20
    /// The floor of the outer radius on the ground, in metres.
    static let minimumFadeEndMeters: Float = 800
    static let minimumFadeEndMetersRange: ClosedRange<Float> = 0 ... 5000

    static func clampCameraDistances(_ cameraDistances: Float, fallback: Float) -> Float {
        guard cameraDistances.isFinite else { return fallback }
        return min(max(cameraDistances, cameraDistancesRange.lowerBound), cameraDistancesRange.upperBound)
    }

    static func clampMinimumFadeEndMeters(_ meters: Float) -> Float {
        guard meters.isFinite else { return minimumFadeEndMeters }
        return min(max(meters, minimumFadeEndMetersRange.lowerBound), minimumFadeEndMetersRange.upperBound)
    }

    /// The ring's radii in world units for this frame's camera distance
    /// (eye to look-at, world units) and metre scale. The outer radius
    /// never falls below the inner, and never below the floor in metres:
    /// when the floor wins, the whole ring scales up to it, so the fade
    /// keeps its proportions. A degenerate camera distance disables the
    /// fade (an infinite ring).
    static func fadeWorldDistances(cameraDistance: Float,
                                   unitsPerMeter: Float = 0,
                                   startCameraDistances: Float = fadeStartCameraDistances,
                                   endCameraDistances: Float = fadeEndCameraDistances,
                                   minimumEndMeters: Float = minimumFadeEndMeters) -> (start: Float, end: Float) {
        guard cameraDistance > 0, cameraDistance.isFinite else {
            return (.infinity, .infinity)
        }
        let endCameraDistances = max(endCameraDistances, startCameraDistances)
        var end = cameraDistance * endCameraDistances
        let floorWorld = unitsPerMeter.isFinite && unitsPerMeter > 0 ? minimumEndMeters * unitsPerMeter : 0
        if end < floorWorld {
            end = floorWorld
        }
        let start = end * (startCameraDistances / endCameraDistances)
        return (start, end)
    }

    /// Whether every point of the placed tile's ground rectangle lies
    /// beyond the outer radius about the look-at point. The nearest point
    /// of the rectangle decides, so a tile that touches the ring keeps its
    /// draws (the shader fades and clips them).
    static func tileBeyondCutoff(centerWorld: SIMD2<Float>,
                                 tileOriginAndSize: SIMD3<Float>,
                                 cutoffWorldDistance: Float) -> Bool {
        guard cutoffWorldDistance.isFinite else { return false }
        let minX = min(tileOriginAndSize.x, tileOriginAndSize.x + tileOriginAndSize.z)
        let maxX = max(tileOriginAndSize.x, tileOriginAndSize.x + tileOriginAndSize.z)
        let minY = min(tileOriginAndSize.y, tileOriginAndSize.y + tileOriginAndSize.z)
        let maxY = max(tileOriginAndSize.y, tileOriginAndSize.y + tileOriginAndSize.z)
        let nearest = SIMD2<Float>(min(max(centerWorld.x, minX), maxX),
                                   min(max(centerWorld.y, minY), maxY))
        return simd_length_squared(centerWorld - nearest) > cutoffWorldDistance * cutoffWorldDistance
    }
}
