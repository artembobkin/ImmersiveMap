// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// GPU buffers сетки полотна карты: вершины, индексы и количество индексов для indexed draw.
struct MapSurfaceGridBuffers {
    let verticesBuffer: MTLBuffer
    let indicesBuffer: MTLBuffer
    let indicesCount: Int
}
