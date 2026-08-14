// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

extension TileMvtParser {
    struct ParsedPolygon {
        var vertices: [SIMD2<Int16>] = []
        var indices: [UInt32] = []
        /// Per-vertex signed distance from a line's centerline, normalized so
        /// the extruded rim is ±`Int8.max`. Empty for plain polygon geometry;
        /// when non-empty it runs in lockstep with `vertices`.
        var lineDistances: [Int8] = []
        /// Per-vertex longitudinal parameter, lockstep with `lineDistances`;
        /// see `TileVertexIn.lineParameter` for the two interpretations
        /// (end-feather distance for solid styles, arc length for
        /// point-dashed ones).
        var lineParameters: [Int16] = []
    }
}
