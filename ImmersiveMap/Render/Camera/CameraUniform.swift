// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

struct CameraUniform {
    let matrix: matrix_float4x4
    let eye: SIMD3<Float>
    let padding: Float
}
