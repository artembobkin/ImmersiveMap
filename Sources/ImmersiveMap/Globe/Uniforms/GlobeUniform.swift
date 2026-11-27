// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import simd

struct GlobeUniform {
    let panX: Float
    let panY: Float
    let radius: Float
    let transition: Float
    
    func getRotation() -> (Float, Float) {
        let xRotation = Float(panY) * Float(ImmersiveMapProjection.maxMercatorLatitude)
        let yRotation = Float(panX) * Float.pi
        return (xRotation, yRotation)
    }
}
