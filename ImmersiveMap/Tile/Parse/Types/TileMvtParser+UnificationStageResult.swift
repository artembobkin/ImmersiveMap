// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

extension TileMvtParser {
    struct UnificationStageResult {
        var drawingPolygon: DrawingPolygonBytes
        var drawingRoadPhases: RoadStructureBuckets<RoadGeometryPhases<DrawingGeometryLayer>>
        var drawingBridgePolygon: DrawingPolygonBytes
        var drawingExtruded: DrawingExtrudedBytes
        var styles: [TilePolygonStyle]
        var overviewStyleMasks: [Float]
        var bridgeStyles: [TilePolygonStyle]
        var bridgeOverviewStyleMasks: [Float]
    }
}
