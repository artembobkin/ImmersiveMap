// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The top of a scene model the frame draws, over the ground it stands
/// on: the model's bounds in the render world, flattened to the footprint
/// they cover and the height they reach. The point labels standing in the
/// building a landmark model replaces take it as their roof, since the
/// tile's own volume of that building is not drawn and may not match the
/// model's height.
struct SceneModelRoof: Equatable {
    /// The footprint in render-world XY, the bounds' shadow on the ground.
    let minimum: SIMD2<Float>
    let maximum: SIMD2<Float>
    /// The top in render-world Z.
    let top: Float

    /// The roof of a model drawn with `modelMatrix` from its asset-space
    /// bounds: the eight corners carried into the render world.
    init(modelMatrix: matrix_float4x4, bounds: SceneModelMesh.Bounds) {
        var minimum = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        var top = -Float.greatestFiniteMagnitude
        for cornerIndex in 0..<8 {
            let corner = SIMD3<Float>(cornerIndex & 1 == 0 ? bounds.minimum.x : bounds.maximum.x,
                                      cornerIndex & 2 == 0 ? bounds.minimum.y : bounds.maximum.y,
                                      cornerIndex & 4 == 0 ? bounds.minimum.z : bounds.maximum.z)
            let world = modelMatrix * SIMD4<Float>(corner, 1)
            minimum = simd_min(minimum, SIMD2(world.x, world.y))
            maximum = simd_max(maximum, SIMD2(world.x, world.y))
            top = max(top, world.z)
        }
        self.minimum = minimum
        self.maximum = maximum
        self.top = top
    }

    init(minimum: SIMD2<Float>, maximum: SIMD2<Float>, top: Float) {
        self.minimum = minimum
        self.maximum = maximum
        self.top = top
    }

    func covers(_ point: SIMD2<Float>) -> Bool {
        point.x >= minimum.x && point.x <= maximum.x && point.y >= minimum.y && point.y <= maximum.y
    }

    /// The tallest roof over `point` among `roofs`, `floor` where none
    /// covers it or none reaches above it.
    static func height(over point: SIMD2<Float>, roofs: [SceneModelRoof], floor: Float) -> Float {
        var height = floor
        for roof in roofs where roof.top > height && roof.covers(point) {
            height = roof.top
        }
        return height
    }
}
