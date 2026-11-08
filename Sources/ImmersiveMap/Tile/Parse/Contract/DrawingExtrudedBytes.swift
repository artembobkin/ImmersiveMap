// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

struct DrawingExtrudedBytes {
    var vertices: [ExtrudedVertexIn]
    var indices: [UInt32]
    var styles: [TilePolygonStyle]
    /// Each building's place in `indices`, sorted by feature id.
    var buildingRanges: [TileBuildingRange] = []
    /// Each volume's anchor, the centre of its footprint's bounds in tile
    /// units (render space), by the ordinal its vertices carry
    /// (`ExtrudedVertexIn.buildingOrdinal`): where the relief's height
    /// under the volume is read.
    var buildingAnchors: [SIMD2<Float>] = []
    /// Where each quarter's volumes start in `indices`, and their count
    /// last, five values, for a tile that keeps its buildings by quarters
    /// (`TileQuarters`). Empty for a tile kept whole.
    var quarterIndexStarts: [UInt32] = []
}
