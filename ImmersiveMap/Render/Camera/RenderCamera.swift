// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit
import Metal

class RenderCamera {
    var projection: matrix_float4x4?
    var view: matrix_float4x4?

    var eye: SIMD3<Float> = SIMD3<Float>(0, 0, 1)
    var center: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
    var up: SIMD3<Float> = SIMD3<Float>(0, 1, 0)

    private(set) var frustrum: Frustum?

    private(set) var cameraMatrix: matrix_float4x4?

    init() {}

    func recalculateProjection(aspect: Float) {
        self.projection = Matrix.perspectiveMatrix(fovRadians: Float.pi / 4, aspect: aspect, near: 0.01, far: 20.0)
        recalculateMatrix()
    }

    func recalculateMatrix() {
        guard let projection else {
            assertionFailure("Render camera projection must be set before recalculating matrices.")
            return
        }
        let view = Matrix.lookAt(eye: eye, center: center, up: up)
        self.view = view
        cameraMatrix = projection * view

        if let cameraMatrix {
            frustrum = Frustum(pv: cameraMatrix)
        } else {
            frustrum = nil
        }
    }
}
