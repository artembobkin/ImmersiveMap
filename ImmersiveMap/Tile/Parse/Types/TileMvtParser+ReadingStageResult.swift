// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

extension TileMvtParser {
    struct ReadingStageResult {
        let polygonByStyle: [UInt8: [ParsedPolygon]]
        let roadPolygonByStyle: [UInt8: [ParsedPolygon]]
        let orderedRoadPolygons: [OrderedRoadPolygon]
        let bridgePolygonByStyle: [UInt8: [ParsedPolygon]]
        let rawLineByStyle: [UInt8: [ParsedLineRawVertices]]
        let extrudedByStyle: [UInt8: [ParsedExtrudedMesh]]
        let styles: [UInt8: FeatureStyle]
        let roadStyles: [UInt8: FeatureStyle]
        let bridgeStyles: [UInt8: FeatureStyle]
        let textLabels: [TextLabel]
        let roadTextLabels: [RoadTextLabel]
        let layerTimings: [TileParseLayerTiming]
    }
}
