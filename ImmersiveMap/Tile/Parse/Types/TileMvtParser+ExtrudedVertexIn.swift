// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

extension TileMvtParser {
    struct ExtrudedVertexIn {
        let position: SIMD3<Float>
        let normal: SIMD3<Float>
        let styleIndex: UInt8
        let _padding0: UInt8 = 0
        let _padding1: UInt8 = 0
        let _padding2: UInt8 = 0
        let surfaceID: UInt32
    }
}
