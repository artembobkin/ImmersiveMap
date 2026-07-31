// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// GPU buffers of the map surface grid: vertices, indices, and the index count for an indexed draw.
struct MapSurfaceGridBuffers {
    let verticesBuffer: MTLBuffer
    let indicesBuffer: MTLBuffer
    let indicesCount: Int
}
