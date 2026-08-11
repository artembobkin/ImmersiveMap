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
        let overviewStyleMask: TileBufferView?
        /// Element width of `indices`: layers within the 16-bit vertex range
        /// are narrowed at build time, oversized ones stay 32-bit.
        let indexType: MTLIndexType

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

        var indicesCount: Int {
            indices?.count ?? 0
        }

        var verticesCount: Int {
            vertices?.count ?? 0
        }
    }

    struct TextLabelSet {
        let placementInputs: [TextLabelPlacementInput]
        let labelsByStyleRuns: [LabelsByStyleRun]
        let poiIconRuns: [PoiIconRunBuffer]

        var labelsCount: Int {
            placementInputs.count
        }
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
    /// nil only for a tile with no GPU content at all. The cache accounts the
    /// tile's byte cost and drives purgeable transitions through it.
    let backingBuffer: MTLBuffer?
    let ground: GeometryLayer
    let roads: RoadStructureBuckets<RoadGeometryPhases<GeometryLayer>>
    let bridgeOverlay: GeometryLayer
    let extruded: Extruded
    let textLabels: TextLabels
    let roadLabels: RoadLabels

    /// Offers the backing allocation to the OS as reclaimable-under-pressure.
    /// Only the cache calls this, and only for tiles outside the demanded set
    /// and the retained placements, past the in-flight frame window.
    func markVolatile() {
        guard let backingBuffer else { return }
        _ = backingBuffer.setPurgeableState(.volatile)
    }

    /// Pins the backing allocation back before reuse. Returns false when the
    /// OS reclaimed its contents while it was volatile: the tile is unusable
    /// and must be dropped and reloaded.
    func restoreFromVolatile() -> Bool {
        guard let backingBuffer else { return true }
        return backingBuffer.setPurgeableState(.nonVolatile) != .empty
    }
}

struct LabelGlyphRange {
    let start: Int
    let count: Int
}
