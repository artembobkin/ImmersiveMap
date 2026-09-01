// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

extension TileMvtParser {
    struct DrawingPolygonBytes {
        var vertices: [TileVertexIn]
        var indices: [UInt32]
        /// Ground bucket only: the indices are ordered fills first (by
        /// ascending style), then line ribbons (by ascending style), and this
        /// is the boundary in index elements. nil means the layer is not
        /// class-split and everything draws as one sequence.
        var fillsIndexCount: Int?

        init(vertices: [TileVertexIn], indices: [UInt32], fillsIndexCount: Int? = nil) {
            self.vertices = vertices
            self.indices = indices
            self.fillsIndexCount = fillsIndexCount
        }
    }
}
