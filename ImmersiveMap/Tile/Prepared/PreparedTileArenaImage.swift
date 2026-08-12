// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// How a prepared tile's geometry blob is stored on disk.
enum PreparedTileGeometryBlobTransport: Equatable, Sendable {
    /// Inside the metadata envelope; readable on every device, materialized
    /// with one CPU copy.
    case inline
    /// In the sibling `.ptgeo` file, loaded straight into the arena buffer by
    /// `MTLIOCommandQueue`.
    case file(PreparedTileFileBlobFormat)
}

/// On-disk encoding of a file-transport geometry blob. Recorded per entry in
/// the metadata (like the envelope's compression flag), so entries written
/// under either `preparedDiskCompressionEnabled` value stay readable.
enum PreparedTileFileBlobFormat: UInt8, Equatable, Sendable {
    /// The raw arena bytes; MTLIO loads the file without a decompression
    /// stage. Written when prepared-disk compression is disabled.
    case raw = 0
    /// An MTLIO compression container (LZFSE chunks), decompressed on the
    /// hardware path during the load.
    case lzfseContainer = 1
}

/// A disk-cache hit in arena-image form: the CPU-only metadata fully decoded,
/// plus the tile's GPU bytes as one blob that byte-matches the arena
/// `MetalTileFactory` would have produced from the original parse. The hit
/// path copies (or DMA-loads) the blob into a fresh arena and rebuilds the
/// buffer views from the span table; no per-array decoding, no earcut, no
/// index narrowing.
struct PreparedTileArenaImage: Sendable {
    /// Transport of the blob bytes. `inline` travels inside the metadata
    /// envelope (already covered by the envelope checksum) and is copied on
    /// the CPU. `file` points at the sibling container: `checksum` is the
    /// word-wise FNV-1a of the decoded arena bytes, stored in the metadata,
    /// and verified after every load. It is what binds a `.ptile` to the
    /// `.ptgeo` content it was saved with: a torn pair, a truncated file, or
    /// bit rot all load "successfully" through MTLIO and are caught only by
    /// this comparison.
    enum GeometryBlob: Sendable {
        case inline(Data)
        case file(url: URL, format: PreparedTileFileBlobFormat, checksum: UInt64)
    }

    /// Per-set CPU metadata: everything `TileBuffers.TextLabelSet` carries
    /// besides the vertex spans. Run styles run in span order (glyph runs
    /// first, then POI icon runs), mirroring the schema traversal.
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
    /// Spans in the canonical `TileArenaSchema` slot order.
    let spans: [TileArenaSpan]
    let arenaByteCount: Int
    let textLabelsFull: TextLabelSetMeta
    let textLabelsReduced: TextLabelSetMeta
    let textLabelsMinimal: TextLabelSetMeta
    let roadLabels: RoadLabelsMeta
    let blob: GeometryBlob
}
