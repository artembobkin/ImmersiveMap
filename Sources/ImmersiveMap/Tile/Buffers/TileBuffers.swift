// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

struct LabelsByStyleRun {
    let style: LabelTextStyle
    let localGlyphVertices: TileBufferView?

    var localGlyphVertexCount: Int {
        localGlyphVertices?.count ?? 0
    }
}

struct PoiIconRunBuffer {
    let style: LabelTextStyle
    let localVertices: TileBufferView?

    var localVertexCount: Int {
        localVertices?.count ?? 0
    }
}

struct RouteShieldRunBuffer {
    let style: RouteShieldRunStyle
    let localVertices: TileBufferView?

    var localVertexCount: Int {
        localVertices?.count ?? 0
    }
}

struct TextLabelPlacementInput {
    let pointInput: TilePointInput
    let placementMeta: LabelPlacementMeta
}

struct TileBuffers {
    // Views are nil for empty layers (a tile without bridges/tunnels has
    // mostly those); every non-empty view points into the one backing
    // allocation below.
    struct GeometryLayer {
        let vertices: TileBufferView?
        let indices: TileBufferView?
        let styles: TileBufferView?
        let styleZoomFade: TileBufferView?
        /// Per-style line parameters (point-locked width, point dash pattern,
        /// edge threshold), lockstep with `styles`; see `TileLineStyle`.
        let lineStyles: TileBufferView?
        /// Element width of `indices`: layers within the 16-bit vertex range
        /// are narrowed at build time, oversized ones stay 32-bit.
        let indexType: MTLIndexType
        /// Ground only: the index buffer's per-style runs in paint order,
        /// what the sphere drawer layers the ground by. Empty elsewhere.
        let styleRuns: [GroundStyleRun]
        /// Ground only: whether the fills are one flattened layer
        /// (`GroundStyleRun.flattenedFlag`), drawn at one depth.
        var isFlattened: Bool {
            styleRuns.contains { $0.isFlattened }
        }
        /// The road buckets only: what the layer's styles say about the
        /// pass it draws in. Empty elsewhere.
        let roadStyles: RoadLayerStyles
        /// The road buckets only: the index element the layer's edge lines
        /// start at, the bodies of its roads lying before it
        /// (`PreparedTileCPU.GeometryLayer.edgeLineIndexStart`). Nil
        /// elsewhere.
        let roadEdgeLineIndexStart: Int?

        init(vertices: TileBufferView?,
             indices: TileBufferView?,
             styles: TileBufferView?,
             styleZoomFade: TileBufferView?,
             lineStyles: TileBufferView?,
             indexType: MTLIndexType,
             styleRuns: [GroundStyleRun] = [],
             roadStyles: RoadLayerStyles = .empty,
             roadEdgeLineIndexStart: Int? = nil) {
            self.vertices = vertices
            self.indices = indices
            self.styles = styles
            self.styleZoomFade = styleZoomFade
            self.lineStyles = lineStyles
            self.indexType = indexType
            self.styleRuns = styleRuns
            self.roadStyles = roadStyles
            self.roadEdgeLineIndexStart = roadEdgeLineIndexStart
        }

        var indicesCount: Int {
            indices?.count ?? 0
        }

        var verticesCount: Int {
            vertices?.count ?? 0
        }
    }

    struct Extruded {
        let vertices: TileBufferView?
        let indices: TileBufferView?
        let styles: TileBufferView?
        /// Element width of `indices`; see `GeometryLayer.indexType`.
        let indexType: MTLIndexType
        /// Each building's place in `indices`, sorted by feature id, see
        /// `TileBuildingRange`.
        var buildingRanges: [TileBuildingRange] = []

        var indicesCount: Int {
            indices?.count ?? 0
        }

        var verticesCount: Int {
            vertices?.count ?? 0
        }

        /// The runs of `indices` to draw when the buildings in
        /// `hiddenFeatureIDs` are left out, in ascending order, nil when
        /// the tile has none of them and draws whole.
        func indexRuns(hiding hiddenFeatureIDs: Set<UInt64>) -> [Range<Int>]? {
            TileBuildingRange.indexRuns(of: buildingRanges, indexCount: indicesCount, hiding: hiddenFeatureIDs)
        }
    }

    struct TextLabelSet {
        let placementInputs: [TextLabelPlacementInput]
        let labelsByStyleRuns: [LabelsByStyleRun]
        let poiIconRuns: [PoiIconRunBuffer]
        let routeShieldRuns: [RouteShieldRunBuffer]
        /// The tile's labels in collision rank order (`BaseLabelRank`), as
        /// indices into `placementInputs`: ranked once here, when the tile
        /// is made, so a working set merges its tiles' orders instead of
        /// sorting every label it holds.
        let rankOrder: [Int32]

        init(placementInputs: [TextLabelPlacementInput],
             labelsByStyleRuns: [LabelsByStyleRun],
             poiIconRuns: [PoiIconRunBuffer],
             routeShieldRuns: [RouteShieldRunBuffer] = []) {
            self.placementInputs = placementInputs
            self.labelsByStyleRuns = labelsByStyleRuns
            self.poiIconRuns = poiIconRuns
            self.routeShieldRuns = routeShieldRuns
            self.rankOrder = BaseLabelRankOrder.sorted(placementInputs.map { BaseLabelRank(placementMeta: $0.placementMeta) })
        }

        var labelsCount: Int {
            placementInputs.count
        }
    }

    struct RoadLabels {
        let pathInputs: [TilePointInput]
        let pathRanges: [RoadPathRange]
        let pathLabels: [RoadPathLabel]
        let labelStyle: LabelTextStyle?
        let localGlyphVertices: TileBufferView?
        let glyphBounds: [SIMD4<Float>]
        let glyphBoundRanges: [LabelGlyphRange]
        let sizes: [SIMD2<Float>]
        let anchorRanges: [RoadLabelAnchorRange]
        let anchors: [RoadLabelAnchor]

        var localGlyphVertexCount: Int {
            localGlyphVertices?.count ?? 0
        }
    }

    /// The tile's single backing allocation: every view above points into it.
    /// nil only for a tile with no GPU content at all. The working-set store
    /// reads the tile's resident byte size from it.
    let backingBuffer: MTLBuffer?
    let ground: GeometryLayer
    let roads: RoadStructureBuckets<RoadGeometryPhases<GeometryLayer>>
    let bridgeOverlay: GeometryLayer
    let extruded: Extruded
    let textLabels: TextLabelSet
    let roadLabels: RoadLabels
    var surfaceLabels: SurfaceLabels = .empty
}

/// The labels painted on the map: one record per label and its glyph quads
/// in the tile's render units, a span of the arena.
struct SurfaceLabels {
    let labels: [SurfaceLabelRecord]
    let vertices: TileBufferView?

    static var empty: SurfaceLabels { SurfaceLabels(labels: [], vertices: nil) }
}

struct LabelGlyphRange {
    let start: Int
    let count: Int
}
