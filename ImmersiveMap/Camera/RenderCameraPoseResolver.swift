// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Synchronizes semantic camera state with the render camera: eye/up vectors, matrices, and frustum.
final class RenderCameraPoseResolver {
    private var needsUpdate = true
    private var appliedTransition: Float?

    func requestUpdate() {
        needsUpdate = true
    }

    /// `transition` is the frame's globe-to-plane phase: on the globe the
    /// camera moves in by the view centre's surface scale
    /// (`GlobeCameraProximity`), and the phase carries that factor through
    /// the morph, so a change of phase alone (the debug panel forcing a
    /// surface) re-poses the camera too.
    func updateIfNeeded(camera: RenderCamera, cameraState: ImmersiveMapCameraState, transition: Float) {
        guard needsUpdate || appliedTransition != transition else {
            return
        }

        let yaw = cameraState.bearing
        let pitch = cameraState.pitch

        let zRemains = cameraState.zoom.truncatingRemainder(dividingBy: 1.0)
        let latitude = ImmersiveMapProjection.latitude(fromNormalizedWorldY: cameraState.centerWorldMercator.y)
        let proximity = GlobeCameraProximity.distanceFactor(latitude: latitude,
                                                            transition: transition,
                                                            zoom: cameraState.zoom)
        let camUp = SIMD3<Float>(0, 1, 0)
        let camPosition = SIMD3<Float>(0, 0, Float((1.0 - zRemains * 0.5) * proximity))
        let camRight = SIMD3<Float>(1, 0, 0)

        let pitchQuat = simd_quatf(angle: pitch, axis: camRight)
        let yawQuat = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 0, 1))

        camera.eye = simd_act(yawQuat * pitchQuat, camPosition)
        camera.up = simd_act(yawQuat * pitchQuat, camUp)

        camera.recalculateMatrix()
        needsUpdate = false
        appliedTransition = transition
    }
}
