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
        /// Ground bucket only: after the line ribbons come the fill outlines,
        /// a LINE list (index pairs over the fill vertices, by ascending
        /// style) the flat drawer rasterizes as one-pixel lines for the
        /// fills' edge antialiasing, and this is where they start. nil means
        /// the layer carries no outline segment.
        var fillOutlinesIndexStart: Int?

        /// The triangle-list part of `indices`: everything before the fill
        /// outline segment, which is a line list and not triangles.
        var triangleIndices: ArraySlice<UInt32> {
            indices[0..<(fillOutlinesIndexStart ?? indices.count)]
        }

        init(vertices: [TileVertexIn],
             indices: [UInt32],
             fillsIndexCount: Int? = nil,
             fillOutlinesIndexStart: Int? = nil) {
            self.vertices = vertices
            self.indices = indices
            self.fillsIndexCount = fillsIndexCount
            self.fillOutlinesIndexStart = fillOutlinesIndexStart
        }
    }
}
