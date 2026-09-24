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
        let styleZoomFades: [SIMD2<Float>]
        /// Per-style line parameters (point-locked width, point dash pattern,
        /// edge threshold), lockstep with `styles`. See `TileLineStyle`.
        let lineStyles: [TileLineStyle]
        /// The class boundary of the ground bucket: indices below it are
        /// polygon fills, indices from it on are line ribbons, each segment
        /// in ascending style order (`unifyPolygonLayer(splitLinesClass:)`).
        /// Layers that are not class-split keep the whole range as fills.
        let fillsIndexCount: Int

        init(vertices: [TileVertexIn],
             indices: [UInt32],
             styles: [TilePolygonStyle],
             styleZoomFades: [SIMD2<Float>],
             lineStyles: [TileLineStyle]? = nil,
             fillsIndexCount: Int? = nil) {
            self.vertices = vertices
            self.indices = indices
            self.styles = styles
            self.styleZoomFades = styleZoomFades
            // nil defaults to plain polygons while keeping the array in
            // lockstep with `styles`: the vertex shader indexes it per style.
            self.lineStyles = lineStyles ?? Array(repeating: .polygon, count: styles.count)
            self.fillsIndexCount = fillsIndexCount ?? indices.count
        }
    }

    struct Extruded {
        let vertices: [ExtrudedVertexIn]
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

    /// The labels painted on the map (`LabelPlacement.surface`): every
    /// glyph quad of the tile in one array, and one record per label naming
    /// its span. A vertex's `position` is its label's anchor in tile render
    /// units (y up, the ground's space) and its `spriteUV` its offset from
    /// the anchor in layout points, which the frame scales into tile units
    /// (`SurfaceLabelScale`). A label's `labelIndex` is its record's index.
    struct SurfaceLabelSet {
        let labels: [SurfaceLabelRecord]
        let vertices: [LabelVertex]

        static let empty = SurfaceLabelSet(labels: [], vertices: [])
    }

    let tile: Tile
    let ground: GeometryLayer
    let roads: RoadStructureBuckets<RoadGeometryPhases<GeometryLayer>>
    let bridgeOverlay: GeometryLayer
    let extruded: Extruded
    /// Every base label of the tile, one set: the frame draws them all and
    /// the collision pass decides what shows.
    let textLabels: TextLabelSet
    let roadLabels: RoadLabels
    var surfaceLabels: SurfaceLabelSet = .empty
}

/// One label painted on the map: what draws it and where its glyph quads
/// sit in the tile's surface label vertices.
struct SurfaceLabelRecord: Sendable {
    /// The label's identity across tiles and zooms: the one copy of a key
    /// that draws is chosen per frame (`SurfaceLabelSelection`).
    let key: UInt64
    let style: LabelTextStyle
    let placement: SurfaceLabelPlacement
    let vertexStart: Int
    let vertexCount: Int
}
