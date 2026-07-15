// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// CPU-only snapshot of a parsed tile.
/// It contains device-independent arrays so the expensive preparation path
/// can be separated from the final MTLBuffer creation stage.
struct PreparedTileCPU: Sendable {
    struct GeometryLayer {
        let vertices: [TilePipeline.VertexIn]
        let indices: [UInt32]
        let styles: [TilePolygonStyle]
        let overviewStyleMasks: [Float]
    }

    struct Extruded {
        let vertices: [TileMvtParser.ExtrudedVertexIn]
        let indices: [UInt32]
        let styles: [TilePolygonStyle]
    }

    struct TextGlyphRun {
        let style: LabelTextStyle
        let localGlyphVertices: [LabelVertex]
    }

    struct PoiIconRun {
        let style: LabelTextStyle
        let localIconVertices: [LabelVertex]
    }

    struct TextLabelSet {
        let placementInputs: [TextLabelPlacementInput]
        let glyphRuns: [TextGlyphRun]
        let poiIconRuns: [PoiIconRun]
    }

    struct TextLabels {
        let full: TextLabelSet
        let reduced: TextLabelSet
        let minimal: TextLabelSet

        func set(for tier: BaseLabelDetailTier) -> TextLabelSet {
            switch tier {
            case .full:
                return full
            case .reduced:
                return reduced
            case .minimal:
                return minimal
            }
        }
    }

    struct RoadLabels {
        let pathInputs: [TilePointInput]
        let pathRanges: [RoadPathRange]
        let pathLabels: [RoadPathLabel]
        let labelStyle: LabelTextStyle?
        let localGlyphVertices: [LabelVertex]
        let glyphBounds: [SIMD4<Float>]
        let glyphBoundRanges: [LabelGlyphRange]
        let sizes: [SIMD2<Float>]
        let anchorRanges: [RoadLabelAnchorRange]
        let anchors: [RoadLabelAnchor]
    }

    let tile: Tile
    let ground: GeometryLayer
    let roads: RoadStructureBuckets<RoadGeometryPhases<GeometryLayer>>
    let bridgeOverlay: GeometryLayer
    let extruded: Extruded
    let textLabels: TextLabels
    let roadLabels: RoadLabels
}
