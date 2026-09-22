// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The tessellators and the clipper one parse works with. `ParsePolygon`
/// keeps scratch buffers between polygons, so a set is made per tile and
/// never shared between the loading threads, which all share one parser.
struct TileParseTools {
    let parsePolygon = ParsePolygon()
    let parseLine = ParseLine()
    let lineClipper = LineClipper()
}
