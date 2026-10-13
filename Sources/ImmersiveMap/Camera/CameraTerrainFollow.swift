// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The camera over a terrain (`GroundReliefStore`): the point it looks at
/// lies on the terrain, raised by the terrain under it
/// (`GroundReliefCameraLift`), so a zoom closes in on the ground and the
/// camera turns about a point on it. A pan moves the eye over the map
/// and keeps its altitude, and the point is where its view ray meets the
/// relief: the zoom, the arm to the point, takes up the terrain's rise and
/// fall (`CameraStateController.followTerrain`). A zoom moves the eye
/// along the ray and finds the point the same way
/// (`CameraStateController.followTerrainZoom`), so a crossing onto
/// another terrain map moves the point, not the eye. The eye rises only
/// where the terrain under the point, or under the eye itself, would
/// otherwise come nearer than the clearance.
///
/// The render world scales with the zoom (`PresentationStateResolver`)
/// and the eye sits about one unit from the point it looks at
/// (`RenderCameraPoseResolver`), so where the eye stands in metres is a
/// function of the zoom, the pitch, the bearing and the latitude: what
/// the pan and the zoom's limit are solved from.
struct CameraTerrainFollow {
    /// The terrain's height in metres under a point of the world
    /// (normalized world mercator), as drawn (the exaggeration in it), nil
    /// where it is not known yet.
    let terrainMetres: (SIMD2<Double>) -> Float?
    /// The height the eye keeps over a ridge under it, the terrain
    /// between the eye and the point that rises over the point
    /// (`clearanceMargin`).
    let clearanceMetres: Double

    /// The margin the eye keeps over the terrain under it, by how far
    /// that terrain rises over the point the eye looks at: nothing where
    /// it lies level with the point or under it, so the eye comes down on
    /// the point as far as the zoom's own limit lets it, growing smoothly
    /// to the clearance over a ridge a clearance higher than the point.
    static func clearanceMargin(rise: Double, clearance: Double) -> Double {
        guard clearance > 0, rise > 0 else { return 0 }
        let t = min(rise / clearance, 1)
        return clearance * t * t * (3 - 2 * t)
    }
    /// `PresentationSettings.globeRadiusScale`, the render world's scale.
    let globeRadiusScale: Double

    /// The eye's height in metres over the point it looks at, for a pose
    /// on the flat map.
    func eyeHeightMetres(zoom: Double, pitch: Float, latitude: Double) -> Double {
        Self.eyeDistanceMetres(zoom: zoom, latitude: latitude, globeRadiusScale: globeRadiusScale)
            * Double(cos(pitch))
    }

    /// How far the eye stands from the point it looks at along the ground,
    /// in metres, for a pose on the flat map.
    func eyeReachMetres(zoom: Double, pitch: Float, latitude: Double) -> Double {
        Self.eyeDistanceMetres(zoom: zoom, latitude: latitude, globeRadiusScale: globeRadiusScale)
            * Double(sin(pitch))
    }

    /// Where the eye stands on the ground, in normalized world mercator,
    /// for a pose on the flat map looking at `center`: behind it along the
    /// bearing by the reach of the pose.
    func eyeGround(center: SIMD2<Double>, zoom: Double, pitch: Float, bearing: Float, latitude: Double) -> SIMD2<Double> {
        let metresPerWorld = ImmersiveMapProjection.earthCircumferenceMeters * max(cos(latitude), 1e-6)
        return center - Self.forward(bearing: bearing) * (eyeReachMetres(zoom: zoom, pitch: pitch, latitude: latitude) / metresPerWorld)
    }

    /// The zoom at which the eye stands `metres` over the point it looks
    /// at, within `range`: the height falls with the zoom without a step,
    /// so the zoom is found by bisection.
    func zoom(forEyeHeightMetres metres: Double, pitch: Float, latitude: Double, range: ClosedRange<Double>) -> Double {
        var low = range.lowerBound
        var high = range.upperBound
        guard eyeHeightMetres(zoom: low, pitch: pitch, latitude: latitude) > metres else { return low }
        guard eyeHeightMetres(zoom: high, pitch: pitch, latitude: latitude) < metres else { return high }
        for _ in 0 ..< 40 {
            let middle = (low + high) * 0.5
            if eyeHeightMetres(zoom: middle, pitch: pitch, latitude: latitude) > metres {
                low = middle
            } else {
                high = middle
            }
        }
        return (low + high) * 0.5
    }

    /// Whether the eye of the pose keeps its margin over the terrain
    /// under itself (`clearanceMargin`). The point is on the terrain, so
    /// the eye stands the pose's height over it, plus the terrain's height
    /// over the plane. Terrain not known yet counts as the plane: nothing
    /// stops a zoom over ground that has not arrived.
    func isClear(center: SIMD2<Double>, zoom: Double, pitch: Float, bearing: Float) -> Bool {
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: center.y)
        let height = eyeHeightMetres(zoom: zoom, pitch: pitch, latitude: latitude)
        let ground = eyeGround(center: center, zoom: zoom, pitch: pitch, bearing: bearing, latitude: latitude)
        let rise = Double(terrainMetres(ground) ?? 0) - Double(terrainMetres(center) ?? 0)
        return height >= rise + Self.clearanceMargin(rise: rise, clearance: clearanceMetres)
    }

    /// `zoom` where the eye keeps the clearance there, else the deepest
    /// zoom below it in `range` where it does: the eye backs off along
    /// its view ray, by the arm, until it clears the terrain under it. A
    /// zoom deeper than `zoom` is never answered, though the eye might be
    /// clear there too, in front of a ridge: the zoom would pass through
    /// the ridge on its way. The boundary is found by bisection between
    /// the range's start, which counts as clear when it is not, and
    /// `zoom`.
    func clearZoom(below zoom: Double, center: SIMD2<Double>, pitch: Float, bearing: Float, range: ClosedRange<Double>) -> Double {
        let zoom = min(max(zoom, range.lowerBound), range.upperBound)
        guard isClear(center: center, zoom: zoom, pitch: pitch, bearing: bearing) == false else {
            return zoom
        }
        guard isClear(center: center, zoom: range.lowerBound, pitch: pitch, bearing: bearing) else {
            return range.lowerBound
        }
        var low = range.lowerBound
        var high = zoom
        for _ in 0 ..< 24 {
            let middle = (low + high) * 0.5
            if isClear(center: center, zoom: middle, pitch: pitch, bearing: bearing) {
                low = middle
            } else {
                high = middle
            }
        }
        return low
    }

    /// The eye's distance from the point it looks at, in metres: the
    /// pose's distance in render units (`RenderCameraPoseResolver`, the
    /// flat map's proximity being 1) over the render units a metre spans
    /// at the latitude, the world being `2^floor(zoom)` times its base
    /// scale (`PresentationStateResolver`).
    static func eyeDistanceMetres(zoom: Double, latitude: Double, globeRadiusScale: Double) -> Double {
        let fraction = zoom.truncatingRemainder(dividingBy: 1.0)
        let distanceUnits = 1.0 - fraction * 0.5
        let renderMapSize = 2.0 * Double.pi * globeRadiusScale * pow(2.0, floor(zoom))
        let unitsPerMetre = ImmersiveMapProjection.worldUnitsPerMeter(latitudeRadians: latitude,
                                                                      renderMapSize: renderMapSize)
        return distanceUnits / unitsPerMetre
    }

    /// The direction the camera looks along the ground, in normalized
    /// world mercator (x east, y south), for a bearing.
    static func forward(bearing: Float) -> SIMD2<Double> {
        SIMD2<Double>(-Double(sin(bearing)), -Double(cos(bearing)))
    }
}
