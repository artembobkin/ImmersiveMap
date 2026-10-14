// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Draws the terrain from under the point the camera looks at. The
/// flattened ground rises by its heights (`GroundReliefStore`) less the
/// terrain under that point, the datum: the point lies at the world's
/// origin, on the ground, so the frame's pose, made for a point on the
/// plane (`RenderCameraPoseResolver`), holds as it is, the camera turns
/// about a point on the ground and a zoom closes in on it, never on a
/// point under it. A pan keeps the eye's own height by the zoom, and the
/// clearance over a ridge under the eye is kept by the zoom too
/// (`CameraTerrainFollow`, `CameraStateController`): the frame never
/// moves the camera off its pose, so the camera's own motion is all the
/// eye ever feels. Everything the frame draws sees the same datum.
///
/// One terrain lookup a frame (`GroundReliefStore.elevation`), a datum
/// every receiver subtracts: nothing per vertex. It is continuous in the
/// camera's place, the terrain being bilinear, so the ground glides under
/// the camera rather than steps.
///
/// Where the centre of the screen meets the terrain (`centreGroundDepth`),
/// not the plane, is what the point-locked road widths are stated at.
enum GroundReliefCameraLift {
    /// The terrain under the point the camera looks at
    /// (`centerWorldMercator`), in metres before the exaggeration: the
    /// frame's datum (`GroundReliefStore.datumMetres`). Read off the
    /// camera's map (`GroundReliefStore.cameraTerrainZoom`), the one map
    /// the camera flies over at every zoom, so the point the camera looks
    /// at is on the ground the camera keeps its height by. Zero over
    /// tiles coarser than the relief's zoom (`tileZoom`, the frame's),
    /// which lie on the plane. Nil while the terrain under the point is
    /// on its way.
    static func datumMetres(store: GroundReliefStore,
                            centerWorldMercator: SIMD2<Double>,
                            tileZoom: Int) -> Float? {
        guard tileZoom >= store.fromTileZoom else {
            return 0
        }
        return store.elevation(atNormalizedWorld: centerWorldMercator, terrainZoom: store.cameraTerrainZoom)
    }

    /// The view depth of the point where the centre of the screen meets
    /// the terrain, drawn from the store's datum, what the point-locked
    /// road widths are stated at, nil where the terrain under the centre
    /// is on its way or the centre ray misses the ground. `cameraMatrix`
    /// is the frame's projection-view. The terrain
    /// is bilinear and the ray is walked onto it in a few steps: from
    /// where it meets the plane, to the plane of the terrain's height
    /// there, and again, which settles in three for any slope a camera
    /// looks down on.
    static func centreGroundDepth(store: GroundReliefStore,
                                  cameraMatrix: matrix_float4x4,
                                  centerWorldMercator: SIMD2<Double>,
                                  tileZoom: Int,
                                  renderMapSize: Double) -> Float? {
        guard tileZoom >= store.fromTileZoom else {
            return nil
        }
        let inverse = cameraMatrix.inverse
        let nearClip = inverse * SIMD4<Float>(0, 0, 0, 1)
        let farClip = inverse * SIMD4<Float>(0, 0, 1, 1)
        guard abs(nearClip.w) > .leastNormalMagnitude, abs(farClip.w) > .leastNormalMagnitude else {
            return nil
        }
        let near = SIMD3<Float>(nearClip.x, nearClip.y, nearClip.z) / nearClip.w
        let far = SIMD3<Float>(farClip.x, farClip.y, farClip.z) / farClip.w
        let descent = near.z - far.z
        guard abs(descent) > .leastNormalMagnitude else {
            return nil
        }
        let zoom = GroundReliefStore.terrainZoom(forTargetZoom: tileZoom)
        var height: Float = 0
        var ground = near
        for _ in 0 ..< 3 {
            let t = (near.z - height) / descent
            guard t.isFinite, t > 0 else {
                return nil
            }
            ground = near + (far - near) * t
            let point = centerWorldMercator + SIMD2<Double>(Double(ground.x), -Double(ground.y)) / renderMapSize
            guard let drawn = store.drawnMetres(atNormalizedWorld: point, terrainZoom: zoom) else {
                return nil
            }
            let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: point.y)
            let unitsPerMetre = Float(ImmersiveMapProjection.worldUnitsPerMeter(latitudeRadians: latitude,
                                                                                renderMapSize: renderMapSize))
            height = (drawn - store.datumMetres) * unitsPerMetre
        }
        let depth = (cameraMatrix * SIMD4<Float>(ground.x, ground.y, height, 1)).w
        return depth.isFinite && depth > 0 ? depth : nil
    }
}
