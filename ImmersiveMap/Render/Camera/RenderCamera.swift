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
        // Far-плоскость должна быть много дальше видимой земли: на плоской карте
        // с наклоном линия среза far и есть видимый «горизонт», и при far = 20
        // она прыгала на ~13 px при каждом пересечении целого зума (рендерный
        // масштаб мира удваивается, а срез остаётся на тех же 20 единицах).
        // При far = 200 срез лежит в пределах ~пикселя от линии схода, чьё
        // положение от зума не зависит.
        self.projection = Matrix.perspectiveMatrix(fovRadians: Float.pi / 4, aspect: aspect, near: 0.01, far: 200.0)
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
