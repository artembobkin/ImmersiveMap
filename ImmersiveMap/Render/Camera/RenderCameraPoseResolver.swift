// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// Синхронизирует semantic camera state с render camera: eye/up vectors, matrices и frustum.
final class RenderCameraPoseResolver {
    private var needsUpdate = true

    func requestUpdate() {
        needsUpdate = true
    }

    func updateIfNeeded(camera: RenderCamera, cameraState: ImmersiveMapCameraState) {
        guard needsUpdate else {
            return
        }

        let yaw = cameraState.bearing
        let pitch = cameraState.pitch

        let zRemains = cameraState.zoom.truncatingRemainder(dividingBy: 1.0)
        let camUp = SIMD3<Float>(0, 1, 0)
        let camPosition = SIMD3<Float>(0, 0, (1.0 - Float(zRemains) * 0.5))
        let camRight = SIMD3<Float>(1, 0, 0)

        let pitchQuat = simd_quatf(angle: pitch, axis: camRight)
        let yawQuat = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 0, 1))

        camera.eye = simd_act(yawQuat * pitchQuat, camPosition)
        camera.up = simd_act(yawQuat * pitchQuat, camUp)

        camera.recalculateMatrix()
        needsUpdate = false
    }
}
