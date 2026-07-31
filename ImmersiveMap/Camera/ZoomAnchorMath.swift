// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import simd

/// Computes the map-center compensation for anchored zoom: the world point under
/// the cursor (the gesture point) stays put on screen, i.e. the camera pulls
/// toward the cursor when zooming in and away from it when zooming out.
///
/// The screen model mirrors the renderer: a perspective camera with fov π/4 at
/// distance `1 - 0.5·frac(zoom)` and a world of size `2π·globeRadiusScale·2^floor(zoom)`
/// (`RenderCameraPoseResolver` + `PresentationStateResolver`). In the globe phase
/// the sphere locally compresses the world near the screen center by `cos(latitude)`,
/// so a linear approximation is used: anchoring is approximate near the globe edges.
/// Camera tilt (pitch) is not modeled.
enum ZoomAnchorMath {
    struct Input {
        /// Gesture point in view coordinates (top-left origin, points).
        let anchorPoint: CGPoint
        /// View size in points.
        let viewportSize: CGSize
        let centerWorldMercator: SIMD2<Double>
        let zoomBefore: Double
        let zoomAfter: Double
        let bearing: Float
        /// Globe→flat phase before and after the zoom: 0 is globe, 1 is flat.
        let transitionBefore: Float
        let transitionAfter: Float
        let globeRadiusScale: Double
        /// Compensation fraction: 0 zooms into the screen center, 1 keeps the point under the cursor fixed.
        let anchorFactor: Double
    }

    /// tan(fov/2) for the fov π/4 from `RenderCamera.recalculateProjection`.
    private static let halfFovTangent = tan(Double.pi / 8.0)

    static func compensatedCenterWorldMercator(_ input: Input) -> SIMD2<Double> {
        let width = Double(input.viewportSize.width)
        let height = Double(input.viewportSize.height)
        let center = input.centerWorldMercator
        guard width > 0,
              height > 0,
              input.anchorFactor > 0,
              input.zoomBefore != input.zoomAfter else {
            return center
        }

        // Anchor offset from the screen center; the screen Y axis (down) is
        // converted to the render axis (up).
        let anchorFromCenter = SIMD2<Double>(Double(input.anchorPoint.x) - width * 0.5,
                                             height * 0.5 - Double(input.anchorPoint.y))
        guard anchorFromCenter != .zero else {
            return center
        }

        // Screen axes → world render axes: the camera is rotated by bearing around Z,
        // so the world vector under screen offset p equals R(bearing)·p.
        let bearing = Double(input.bearing)
        let cosBearing = cos(bearing)
        let sinBearing = sin(bearing)
        let worldDirection = SIMD2<Double>(anchorFromCenter.x * cosBearing - anchorFromCenter.y * sinBearing,
                                           anchorFromCenter.x * sinBearing + anchorFromCenter.y * cosBearing)

        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: center.y)
        let unitsPerPointBefore = normalizedWorldUnitsPerPoint(zoom: input.zoomBefore,
                                                               transition: input.transitionBefore,
                                                               latitude: latitude,
                                                               viewportHeight: height,
                                                               globeRadiusScale: input.globeRadiusScale)
        let unitsPerPointAfter = normalizedWorldUnitsPerPoint(zoom: input.zoomAfter,
                                                              transition: input.transitionAfter,
                                                              latitude: latitude,
                                                              viewportHeight: height,
                                                              globeRadiusScale: input.globeRadiusScale)
        let unitsPerPointDelta = unitsPerPointBefore - unitsPerPointAfter
        guard unitsPerPointDelta.isFinite, unitsPerPointDelta != 0 else {
            return center
        }

        // World point under the anchor: w = c + (unitsPerPoint·worldDirection.x,
        // -unitsPerPoint·worldDirection.y); normalized world Y grows southward,
        // render Y grows northward. Requiring w(before) = w(after) yields the center shift.
        let shift = unitsPerPointDelta * input.anchorFactor
        let compensated = SIMD2<Double>(center.x + worldDirection.x * shift,
                                        center.y - worldDirection.y * shift)
        return SIMD2<Double>(ImmersiveMapProjection.wrapNormalizedWorldX(compensated.x),
                             ImmersiveMapProjection.clampNormalizedWorldY(compensated.y))
    }

    /// Normalized-world units per screen point along the horizontal at the screen center:
    /// q(z) = 2·d(z)·tan(fov/2) / (H·mapSize(z)·surfaceScale).
    /// `surfaceScale` interpolates the local surface scale between the sphere
    /// (cos(lat)) and the plane (1) by the transition phase.
    private static func normalizedWorldUnitsPerPoint(zoom: Double,
                                                     transition: Float,
                                                     latitude: Double,
                                                     viewportHeight: Double,
                                                     globeRadiusScale: Double) -> Double {
        let cameraDistance = 1.0 - 0.5 * zoom.truncatingRemainder(dividingBy: 1.0)
        let renderMapSize = 2.0 * Double.pi * globeRadiusScale * pow(2.0, floor(zoom))
        let surfaceScale = SurfaceScaleMath.surfaceScale(latitude: latitude, transition: transition)
        return (2.0 * cameraDistance * halfFovTangent) / (viewportHeight * renderMapSize * surfaceScale)
    }
}
