// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

extension TileMvtParser {
    struct ParsedPolygon {
        var vertices: [SIMD2<Int16>] = []
        var indices: [UInt32] = []
        /// Per-vertex signed distance from a line's centerline, normalized so
        /// the extruded rim is ±`Int16.max`. Empty for plain polygon geometry;
        /// when non-empty it runs in lockstep with `vertices`.
        var lineDistances: [Int16] = []
        /// Where the styled line edge sits inside the distance field, as a
        /// 0...255 fraction of the extruded half-width. Zero means "not a
        /// line": the shader skips analytic coverage for such geometry.
        var lineEdgeThreshold: UInt8 = 0
    }
}
