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
        /// Per-vertex signed longitudinal distance past the styled cut of a
        /// free butt end, in feather units, normalized so one feather is
        /// `Int8.max`. Saturated at `Int8.max` for interior vertices and for
        /// cuts that must stay hard (tile seams, road junctions). Lockstep
        /// with `lineDistances`.
        var lineEndDistances: [Int8] = []
        /// Where the styled line edge sits inside the distance field, as a
        /// 0...255 fraction of the extruded half-width. Zero means "not a
        /// line": the shader skips analytic coverage for such geometry.
        var lineEdgeThreshold: UInt8 = 0
    }
}
