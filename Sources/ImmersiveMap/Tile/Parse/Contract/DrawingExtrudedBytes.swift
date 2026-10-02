// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

struct DrawingExtrudedBytes {
    var vertices: [ExtrudedVertexIn]
    var indices: [UInt32]
    var styles: [TilePolygonStyle]
    /// Each building's place in `indices`, sorted by feature id.
    var buildingRanges: [TileBuildingRange] = []
}
