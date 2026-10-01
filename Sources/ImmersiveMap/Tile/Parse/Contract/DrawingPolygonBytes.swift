// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

struct DrawingPolygonBytes {
    var vertices: [TileVertexIn]
    var indices: [UInt32]
    /// Ground bucket only: the indices are ordered fills first (by
    /// ascending style), then line ribbons (by ascending style), and this
    /// is the boundary in index elements. nil means the layer is not
    /// class-split and everything draws as one sequence.
    var fillsIndexCount: Int?
    /// Road buckets only: the indices are the bodies of the roads, as
    /// triangles, then their edge lines, as line segments, and this is the
    /// boundary in index elements. nil means the layer carries no edge
    /// lines.
    var edgeLineIndexStart: Int?

    init(vertices: [TileVertexIn],
         indices: [UInt32],
         fillsIndexCount: Int? = nil,
         edgeLineIndexStart: Int? = nil) {
        self.vertices = vertices
        self.indices = indices
        self.fillsIndexCount = fillsIndexCount
        self.edgeLineIndexStart = edgeLineIndexStart
    }
}
