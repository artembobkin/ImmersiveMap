// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// CPU-only snapshot of a parsed tile.
/// It contains device-independent arrays so the expensive preparation path
/// can be separated from the final MTLBuffer creation stage.
struct PreparedTileCPU: Sendable {
    struct GeometryLayer {
        let vertices: [TileVertexIn]
        let indices: [UInt32]
        let styles: [TilePolygonStyle]
        let overviewStyleMasks: [Float]
        /// Per-style line parameters (point-locked width, point dash pattern,
        /// edge threshold), lockstep with `styles`. See `TileLineStyle`.
        let lineStyles: [TileLineStyle]
        /// The class boundary of the ground bucket: indices below it are
        /// polygon fills, indices from it on are line ribbons, each segment
        /// in ascending style order (`unifyPolygonLayer(splitLinesClass:)`).
        /// Layers that are not class-split keep the whole range as fills.
        let fillsIndexCount: Int
        /// The third class segment of the ground bucket: from here to the end
        /// the indices are the fill outlines, a LINE list of index pairs over
        /// the fill vertices in ascending style order, which the flat drawer
        /// rasterizes as one-pixel lines for the fills' edge antialiasing.
        /// Equal to `indices.count` when the layer carries none.
        let fillOutlinesIndexStart: Int

        init(vertices: [TileVertexIn],
             indices: [UInt32],
             styles: [TilePolygonStyle],
             overviewStyleMasks: [Float],
             lineStyles: [TileLineStyle]? = nil,
             fillsIndexCount: Int? = nil,
             fillOutlinesIndexStart: Int? = nil) {
            self.vertices = vertices
            self.indices = indices
            self.styles = styles
            self.overviewStyleMasks = overviewStyleMasks
            // nil defaults to plain polygons while keeping the array in
            // lockstep with `styles`: the vertex shader indexes it per style.
            self.lineStyles = lineStyles ?? Array(repeating: .polygon, count: styles.count)
            self.fillOutlinesIndexStart = fillOutlinesIndexStart ?? indices.count
            self.fillsIndexCount = fillsIndexCount ?? self.fillOutlinesIndexStart
        }
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
