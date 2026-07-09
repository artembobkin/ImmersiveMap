// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

extension TileMvtParser {
    struct DrawingExtrudedBytes {
        var vertices: [ExtrudedVertexIn]
        var indices: [UInt32]
        var styles: [TilePolygonStyle]
    }
}
