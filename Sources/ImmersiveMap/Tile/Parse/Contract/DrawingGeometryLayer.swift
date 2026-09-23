// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// One drawable layer of a tile's prepared geometry: the unified vertex
/// and index streams and the style tables they index into, as the tile
/// factory uploads them.
struct DrawingGeometryLayer {
    let drawing: DrawingPolygonBytes
    let styles: [TilePolygonStyle]
    let styleZoomFades: [SIMD2<Float>]
    let lineStyles: [TileLineStyle]
}
