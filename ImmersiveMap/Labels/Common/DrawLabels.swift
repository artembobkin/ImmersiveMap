// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

struct LabelsDrawBatch {
    let labelsByStyleRuns: [LabelsByStyleRun]
    let poiIconRuns: [PoiIconRunBuffer]
    let labelInstanceCount: Int
}

struct BaseLabelDrawBatch {
    let labelsByStyleRuns: [LabelsByStyleRun]
    let poiIconRuns: [PoiIconRunBuffer]
    let globalLabelStart: Int
    let labelInstanceCount: Int
}

struct DrawRoadLabels {
    let placementBuffer: MTLBuffer?
    let glyphInputBuffer: MTLBuffer?
    let runtimeMetaBuffer: MTLBuffer?
    let localGlyphVerticesBuffer: MTLBuffer?
    let glyphCount: Int
    let localGlyphVertexCount: Int
    let labelStyle: LabelTextStyle?
}
