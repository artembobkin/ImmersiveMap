// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

extension TileMvtParser {
    struct ParsedLineRawVertices {
        let vertices: [SIMD3<Float>]
        let indices: [UInt32]
    }
}
