// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

extension TileMvtParser {
    struct ParsedExtrudedVertex {
        let position: SIMD3<Float>
        let normal: SIMD3<Float>
        let surfaceID: UInt32
    }

    struct ParsedExtrudedMesh {
        var vertices: [ParsedExtrudedVertex]
        var indices: [UInt32]
    }
}
