// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import simd

struct GlobeUniform {
    let panX: Float
    let panY: Float
    let radius: Float
    let transition: Float
    
    func getRotation() -> (Float, Float) {
        let maxLatitude = 2.0 * atan(exp(Double.pi)) - (Double.pi / 2.0);
        let xRotation = Float(panY) * Float(maxLatitude)
        let yRotation = Float(panX) * Float.pi
        return (xRotation, yRotation)
    }
}
