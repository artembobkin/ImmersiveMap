// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// A disk-cache hit in arena-image form: the CPU-only metadata fully decoded,
/// plus the tile's GPU bytes as one blob that byte-matches the arena
/// `MetalTileFactory` would have produced from the original parse. The hit
/// path copies (or DMA-loads) the blob into a fresh arena and rebuilds the
/// buffer views from the span table; no per-array decoding, no earcut, no
/// index narrowing.
struct PreparedTileArenaImage: Sendable {
    /// Transport of the blob bytes. `inline` travels inside the metadata
    /// envelope and is copied on the CPU; `file` points at an MTLIO
    /// compression container next to the metadata file, loaded straight into
    /// the arena buffer by `MTLIOCommandQueue` with hardware LZFSE.
    enum GeometryBlob: Sendable {
        case inline(Data)
        case file(URL)
    }

    /// Per-set CPU metadata: everything `TileBuffers.TextLabelSet` carries
    /// besides the vertex spans. Run styles run in span order (glyph runs
    /// first, then POI icon runs), mirroring the plan traversal.
    struct TextLabelSetMeta: Sendable {
        let placementInputs: [TextLabelPlacementInput]
        let glyphRunStyles: [LabelTextStyle]
        let poiIconRunStyles: [LabelTextStyle]
    }

    struct RoadLabelsMeta: Sendable {
        let pathInputs: [TilePointInput]
        let pathRanges: [RoadPathRange]
        let pathLabels: [RoadPathLabel]
        let labelStyle: LabelTextStyle?
        let glyphBounds: [SIMD4<Float>]
        let glyphBoundRanges: [LabelGlyphRange]
        let sizes: [SIMD2<Float>]
        let anchorRanges: [RoadLabelAnchorRange]
        let anchors: [RoadLabelAnchor]
    }

    let tile: Tile
    /// Spans in the canonical `TileArenaImageMath` traversal order.
    let spans: [TileArenaSpan]
    let arenaByteCount: Int
    let textLabelsFull: TextLabelSetMeta
    let textLabelsReduced: TextLabelSetMeta
    let textLabelsMinimal: TextLabelSetMeta
    let roadLabels: RoadLabelsMeta
    let blob: GeometryBlob
}
