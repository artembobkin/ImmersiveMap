// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// One tile's base labels to draw: its parse-time vertex runs and where its
/// labels start in the packed working set, which the shaders add to each
/// vertex's tile-local label index.
struct BaseLabelDrawBatch {
    let labelsByStyleRuns: [LabelsByStyleRun]
    let poiIconRuns: [PoiIconRunBuffer]
    let routeShieldRuns: [RouteShieldRunBuffer]
    let globalLabelStart: Int
    let labelInstanceCount: Int
}

/// One tile's road labels to draw: the frame's glyph placements and the
/// instances' fade alphas beside the tile's static glyph data and vertices.
struct DrawRoadLabels {
    let placementBuffer: MTLBuffer
    let glyphInputBuffer: MTLBuffer
    let runtimeMetaBuffer: MTLBuffer
    let localGlyphVertices: TileBufferView
    let labelStyle: LabelTextStyle

    var localGlyphVertexCount: Int {
        localGlyphVertices.count
    }
}
