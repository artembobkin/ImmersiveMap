// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

extension TileMvtParser {
    struct DrawingPolygonBytes {
        var vertices: [TilePipeline.VertexIn]
        var indices: [UInt32]
    }
}
