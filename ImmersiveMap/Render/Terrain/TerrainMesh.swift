// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

struct TerrainMesh: Equatable {
    struct Vertex: Equatable {
        let position: SIMD3<Float>
        let normal: SIMD3<Float>
        let color: SIMD4<Float>
    }

    let tile: Tile
    let vertices: [Vertex]
    let indices: [UInt32]
}
