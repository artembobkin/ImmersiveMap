// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Draws the terrain from under the point the camera looks at. The
/// flattened ground rises by its heights (`GroundReliefStore`) less the
/// terrain under that point, the datum: the point lies at the world's
/// origin, on the ground, so the frame's pose, made for a point on the
/// plane (`RenderCameraPoseResolver`), holds as it is, the camera turns
/// about a point on the ground and a zoom closes in on it, never on a
/// point under it. A pan keeps the eye's own height by the zoom
/// (`CameraTerrainFollow`). Where the terrain under the eye itself (a
/// ridge between the eye and the point) would come nearer than the
/// clearance (`GroundReliefSettings.cameraClearanceMetres`), the camera
/// is raised by just what it lacks, so it never sinks into a hill. Over
/// ground level with the point nothing holds it off.
/// Everything the frame draws sees the same datum and the same camera.
///
/// Two terrain lookups a frame (`GroundReliefStore.elevation`), a datum
/// every receiver subtracts and at most one translation folded into the
/// matrices: nothing per vertex. Both are continuous in the camera's
/// place, the terrain being bilinear, so the ground glides under the
/// camera rather than steps.
///
/// Where the centre of the screen meets the terrain (`centreGroundDepth`),
/// not the plane, is what the point-locked road widths are stated at.
enum GroundReliefCameraLift {
    /// The terrain under the point the camera looks at
    /// (`centerWorldMercator`), in metres before the exaggeration: the
    /// frame's datum (`GroundReliefStore.datumMetres`). Read at the zoom
    /// of the frame's tiles, or of the flattened ones when the frame's
    /// are coarser. Zero over tiles coarser than the relief's zoom, which
    /// lie on the plane. Nil while the terrain under the point is on its
    /// way.
    static func datumMetres(store: GroundReliefStore,
                            centerWorldMercator: SIMD2<Double>,
                            tileZoom: Int) -> Float? {
        guard tileZoom >= store.fromTileZoom else {
            return 0
        }
        return store.elevation(atNormalizedWorld: centerWorldMercator,
                               terrainZoom: GroundReliefStore.terrainZoom(forTargetZoom: tileZoom))
    }

    /// How far the camera rises over its pose this frame, in world units:
    /// what the eye lacks of its margin over the terrain under it
    /// (`CameraTerrainFollow.clearanceMargin`), drawn from the store's
    /// datum. `eye` is the frame's eye in the flat world, whose origin is
    /// the point the camera looks at. Zero over tiles coarser than the
    /// relief's zoom. Nil while the terrain under the eye is on its way.
    static func clearanceLiftUnits(store: GroundReliefStore,
                                   eye: SIMD3<Float>,
                                   centerWorldMercator: SIMD2<Double>,
                                   tileZoom: Int,
                                   renderMapSize: Double) -> Float? {
        guard tileZoom >= store.fromTileZoom else {
            return 0
        }
        let zoom = GroundReliefStore.terrainZoom(forTargetZoom: tileZoom)
        // The world is y-up, normalized world mercator y-down.
        let eyeGround = centerWorldMercator + SIMD2<Double>(Double(eye.x), -Double(eye.y)) / renderMapSize
        guard let eyeMetres = store.elevation(atNormalizedWorld: eyeGround, terrainZoom: zoom) else {
            return nil
        }
        let eyeLatitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: eyeGround.y)
        let eyeUnitsPerMetre = Float(ImmersiveMapProjection.worldUnitsPerMeter(latitudeRadians: eyeLatitude,
                                                                               renderMapSize: renderMapSize))
        let rise = Double((eyeMetres - store.datumMetres) * store.exaggeration)
        let margin = CameraTerrainFollow.clearanceMargin(rise: rise, clearance: Double(store.cameraClearanceMetres))
        let lowestEye = Float(rise + margin) * eyeUnitsPerMetre
        return max(0, lowestEye - eye.z)
    }

    /// The view depth of the point where the centre of the screen meets
    /// the terrain, drawn from the store's datum, what the point-locked
    /// road widths are stated at, nil where the terrain under the centre
    /// is on its way or the centre ray misses the ground. `cameraMatrix`
    /// is the frame's projection-view with any lift applied. The terrain
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
            guard let metres = store.elevation(atNormalizedWorld: point, terrainZoom: zoom) else {
                return nil
            }
            let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: point.y)
            let unitsPerMetre = Float(ImmersiveMapProjection.worldUnitsPerMeter(latitudeRadians: latitude,
                                                                                renderMapSize: renderMapSize))
            height = (metres - store.datumMetres) * store.exaggeration * unitsPerMetre
        }
        let depth = (cameraMatrix * SIMD4<Float>(ground.x, ground.y, height, 1)).w
        return depth.isFinite && depth > 0 ? depth : nil
    }

    /// The frame's camera raised by `units`: the world moved down under
    /// the view, the eye moved up. The screen matrix is the screen's and
    /// stays.
    static func lifted(_ matrices: FrameCameraMatrices,
                       eye: SIMD3<Float>,
                       by units: Float) -> (matrices: FrameCameraMatrices, eye: SIMD3<Float>) {
        guard units != 0 else {
            return (matrices, eye)
        }
        var lowering = matrix_identity_float4x4
        lowering.columns.3 = SIMD4<Float>(0, 0, -units, 1)
        return (FrameCameraMatrices(projectionView: matrices.projectionView * lowering,
                                    view: matrices.view * lowering,
                                    screen: matrices.screen),
                eye + SIMD3<Float>(0, 0, units))
    }
}
