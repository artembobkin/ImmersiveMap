// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

struct LabelsByStyleRun {
    let style: LabelTextStyle
    let localGlyphVerticesBuffer: MTLBuffer?
    let localGlyphVertexCount: Int
}

struct PoiIconRunBuffer {
    let style: LabelTextStyle
    let localVerticesBuffer: MTLBuffer?
    let localVertexCount: Int
}

struct TextLabelPlacementInput {
    let pointInput: TilePointInput
    let placementMeta: LabelPlacementMeta
}

struct TileBuffers {
    // Buffers are nil for empty layers (a tile without bridges/tunnels has mostly those):
    // even a minimum-size stub would still cost an allocation page
    // and a resource-table slot for each of the tile's dozens of buffers.
    struct GeometryLayer {
        let verticesBuffer: MTLBuffer?
        let indicesBuffer: MTLBuffer?
        let stylesBuffer: MTLBuffer?
        let overviewStyleMaskBuffer: MTLBuffer?
        let indicesCount: Int
        let verticesCount: Int
        /// Element width of `indicesBuffer`: layers within the 16-bit vertex
        /// range are narrowed at buffer creation, oversized ones stay 32-bit.
        let indexType: MTLIndexType
    }

    struct Extruded {
        let verticesBuffer: MTLBuffer?
        let indicesBuffer: MTLBuffer?
        let stylesBuffer: MTLBuffer?
        let indicesCount: Int
        let verticesCount: Int
        /// Element width of `indicesBuffer`; see `GeometryLayer.indexType`.
        let indexType: MTLIndexType
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
        let localGlyphVerticesBuffer: MTLBuffer?
        let localGlyphVertexCount: Int
        let glyphBounds: [SIMD4<Float>]
        let glyphBoundRanges: [LabelGlyphRange]
        let sizes: [SIMD2<Float>]
        let anchorRanges: [RoadLabelAnchorRange]
        let anchors: [RoadLabelAnchor]
    }

    let ground: GeometryLayer
    let roads: RoadStructureBuckets<RoadGeometryPhases<GeometryLayer>>
    let bridgeOverlay: GeometryLayer
    let extruded: Extruded
    let textLabels: TextLabels
    let roadLabels: RoadLabels

    /// Enumerates every Metal buffer the tile owns: the cache uses it for
    /// byte accounting and purgeable-state transitions.
    func forEachBuffer(_ body: (MTLBuffer) -> Void) {
        let geometryLayers = [ground] + roads.drawOrderBuckets.flatMap(\.drawOrderLayers) + [bridgeOverlay]
        for layer in geometryLayers {
            for buffer in [layer.verticesBuffer, layer.indicesBuffer,
                           layer.stylesBuffer, layer.overviewStyleMaskBuffer] {
                if let buffer { body(buffer) }
            }
        }
        for buffer in [extruded.verticesBuffer, extruded.indicesBuffer, extruded.stylesBuffer] {
            if let buffer { body(buffer) }
        }
        for labelSet in [textLabels.full, textLabels.reduced, textLabels.minimal] {
            for run in labelSet.labelsByStyleRuns {
                if let buffer = run.localGlyphVerticesBuffer { body(buffer) }
            }
            for run in labelSet.poiIconRuns {
                if let buffer = run.localVerticesBuffer { body(buffer) }
            }
        }
        if let buffer = roadLabels.localGlyphVerticesBuffer { body(buffer) }
    }

    /// Offers every buffer to the OS as reclaimable-under-pressure. Only the
    /// cache calls this, and only for tiles outside the demanded set and the
    /// retained placements, past the in-flight frame window.
    func markVolatile() {
        forEachBuffer { buffer in
            _ = buffer.setPurgeableState(.volatile)
        }
    }

    /// Pins the buffers back before reuse. Returns false when the OS
    /// reclaimed any buffer's contents while it was volatile: the tile is
    /// unusable and must be dropped and reloaded.
    func restoreFromVolatile() -> Bool {
        var contentsRetained = true
        forEachBuffer { buffer in
            if buffer.setPurgeableState(.nonVolatile) == .empty {
                contentsRetained = false
            }
        }
        return contentsRetained
    }
}

struct LabelGlyphRange {
    let start: Int
    let count: Int
}
