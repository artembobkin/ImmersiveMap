// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// What the unification stage produces: every layer packed into its GPU
/// streams, which `parse` wraps into the `ParsedTile`.
struct UnificationStageResult {
    var drawingPolygon: DrawingPolygonBytes
    var drawingRoadPhases: RoadStructureBuckets<RoadGeometryPhases<DrawingGeometryLayer>>
    var drawingBridgePolygon: DrawingPolygonBytes
    var drawingExtruded: DrawingExtrudedBytes
    var styles: [TilePolygonStyle]
    var styleZoomFades: [SIMD2<Float>]
    var lineStyles: [TileLineStyle]
    var bridgeStyles: [TilePolygonStyle]
    var bridgeStyleZoomFades: [SIMD2<Float>]
    var bridgeLineStyles: [TileLineStyle]
}
