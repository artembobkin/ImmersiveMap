// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Distance LOD for road paint: the marking styles (lane lines, centre
/// dividers, crosswalks; the fade band `roadMarkingLowZoomFadeMask`) are
/// world-locked widths of fractions of a metre, so beyond a certain camera
/// distance they are sub-pixel and the analytic antialiasing has already
/// faded them to a smear that blends into the carriageway. A tile whose
/// nearest point lies beyond that distance skips its marking runs entirely:
/// no vertices, no fragments, no binds. The threshold is resolvability, not
/// taste: at the cutoff the thinnest marking is under half a pixel wide, so
/// a tile crossing the boundary cannot pop visibly.
enum RoadMarkingDistanceLOD {
    /// The thinnest painted marking, in metres (a lane line).
    static let thinnestMarkingMetres: Float = 0.30
    /// The on-screen width below which the paint no longer resolves.
    static let minimumResolvablePixels: Float = 0.45

    /// The camera distance (in world units) past which the thinnest marking
    /// falls under the resolvable width, for a perspective camera with the
    /// render camera's fixed vertical field of view.
    static func cutoffWorldDistance(drawableHeightPx: Float, unitsPerMeter: Float) -> Float {
        guard drawableHeightPx > 0, unitsPerMeter > 0,
              drawableHeightPx.isFinite, unitsPerMeter.isFinite else {
            return .infinity
        }
        let focalPx = (drawableHeightPx * 0.5) / tan(RenderCamera.verticalFovRadians * 0.5)
        return thinnestMarkingMetres * unitsPerMeter * focalPx / minimumResolvablePixels
    }

    /// Whether every point of the placed tile lies beyond the cutoff. The
    /// nearest point of the tile's ground rectangle decides, so a tile that
    /// touches the resolvable zone keeps its markings whole.
    static func tileBeyondCutoff(cameraEye: SIMD3<Float>,
                                 tileOriginAndSize: SIMD3<Float>,
                                 cutoffWorldDistance: Float) -> Bool {
        guard cutoffWorldDistance.isFinite else { return false }
        let minX = min(tileOriginAndSize.x, tileOriginAndSize.x + tileOriginAndSize.z)
        let maxX = max(tileOriginAndSize.x, tileOriginAndSize.x + tileOriginAndSize.z)
        let minY = min(tileOriginAndSize.y, tileOriginAndSize.y + tileOriginAndSize.z)
        let maxY = max(tileOriginAndSize.y, tileOriginAndSize.y + tileOriginAndSize.z)
        let nearestX = min(max(cameraEye.x, minX), maxX)
        let nearestY = min(max(cameraEye.y, minY), maxY)
        let dx = cameraEye.x - nearestX
        let dy = cameraEye.y - nearestY
        let dz = cameraEye.z
        return dx * dx + dy * dy + dz * dz > cutoffWorldDistance * cutoffWorldDistance
    }
}
