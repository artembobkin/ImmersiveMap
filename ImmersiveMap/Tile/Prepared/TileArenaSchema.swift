// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// Semantic identity of one span in a tile's arena image. A slot names what
/// the bytes are (which layer, which run), not where they sit; offsets and
/// sizes live in the span table.
enum TileArenaSlot: Equatable, Sendable {
    case geometryVertices(TileArenaGeometryLayerID)
    case geometryIndices(TileArenaGeometryLayerID)
    case geometryStyles(TileArenaGeometryLayerID)
    case geometryOverviewStyleMasks(TileArenaGeometryLayerID)
    case geometryLineStyles(TileArenaGeometryLayerID)
    case extrudedVertices
    case extrudedIndices
    case extrudedStyles
    case glyphRunVertices(tier: BaseLabelDetailTier, run: Int)
    case poiIconRunVertices(tier: BaseLabelDetailTier, run: Int)
    case roadLabelGlyphVertices
}

/// The geometry layers a tile carries, in schema vocabulary.
enum TileArenaGeometryLayerID: Equatable, Sendable {
    case ground
    case road(TileMvtParser.RoadStructureKind, RoadPassRole)
    case bridgeOverlay
}

/// Glyph-run and POI-icon-run counts of one text label set; the only
/// data-dependent part of the slot sequence.
struct TileArenaTextRunCounts: Equatable, Sendable {
    let glyphRunCount: Int
    let poiIconRunCount: Int
}

/// The single source of truth for the arena-image traversal: the canonical
/// slot sequence, and the element stride of every non-index slot.
///
/// `TileArenaImageMath.plan` iterates this sequence to lay the arena out,
/// `MetalTileFactory` iterates it to read the arena back (every span take is
/// verified against the expected slot, so a reordered reader fails instead of
/// binding bytes to the wrong destination), and the disk codec validates
/// untrusted span tables against it. The sequence, the strides, the 256-byte
/// alignment, and the index narrowing together are the prepared-cache format:
/// changing any of them means bumping
/// `PreparedTileDiskCaching.preparedFormatVersion`.
enum TileArenaSchema {
    /// The canonical slot sequence: ground, road buckets x phases (in their
    /// draw orders), bridge overlay, extruded, text label sets by tier (glyph
    /// runs, then POI icon runs), road label glyphs.
    static func slots(full: TileArenaTextRunCounts,
                      reduced: TileArenaTextRunCounts,
                      minimal: TileArenaTextRunCounts) -> [TileArenaSlot] {
        var slots: [TileArenaSlot] = []
        appendGeometryLayer(.ground, to: &slots)
        for structureKind in TileMvtParser.RoadStructureKind.drawOrder {
            for passRole in RoadPassRole.drawOrder {
                appendGeometryLayer(.road(structureKind, passRole), to: &slots)
            }
        }
        appendGeometryLayer(.bridgeOverlay, to: &slots)

        slots.append(.extrudedVertices)
        slots.append(.extrudedIndices)
        slots.append(.extrudedStyles)

        for (tier, counts) in [(BaseLabelDetailTier.full, full),
                               (BaseLabelDetailTier.reduced, reduced),
                               (BaseLabelDetailTier.minimal, minimal)] {
            for run in 0..<counts.glyphRunCount {
                slots.append(.glyphRunVertices(tier: tier, run: run))
            }
            for run in 0..<counts.poiIconRunCount {
                slots.append(.poiIconRunVertices(tier: tier, run: run))
            }
        }
        slots.append(.roadLabelGlyphVertices)
        return slots
    }

    static func slots(for preparedTile: PreparedTileCPU) -> [TileArenaSlot] {
        slots(full: runCounts(of: preparedTile.textLabels.full),
              reduced: runCounts(of: preparedTile.textLabels.reduced),
              minimal: runCounts(of: preparedTile.textLabels.minimal))
    }

    static func slots(for image: PreparedTileArenaImage) -> [TileArenaSlot] {
        slots(full: runCounts(of: image.textLabelsFull),
              reduced: runCounts(of: image.textLabelsReduced),
              minimal: runCounts(of: image.textLabelsMinimal))
    }

    static func runCounts(of set: PreparedTileCPU.TextLabelSet) -> TileArenaTextRunCounts {
        TileArenaTextRunCounts(glyphRunCount: set.glyphRuns.count,
                               poiIconRunCount: set.poiIconRuns.count)
    }

    static func runCounts(of meta: PreparedTileArenaImage.TextLabelSetMeta) -> TileArenaTextRunCounts {
        TileArenaTextRunCounts(glyphRunCount: meta.glyphRunStyles.count,
                               poiIconRunCount: meta.poiIconRunStyles.count)
    }

    /// Element stride of a slot's span, nil for index slots (their stride is
    /// the index width recorded in the span, uint16 after narrowing or
    /// uint32).
    static func elementStride(of slot: TileArenaSlot) -> Int? {
        switch slot {
        case .geometryVertices:
            return MemoryLayout<TileVertexIn>.stride
        case .extrudedVertices:
            return MemoryLayout<TileMvtParser.ExtrudedVertexIn>.stride
        case .geometryStyles, .extrudedStyles:
            return MemoryLayout<TilePolygonStyle>.stride
        case .geometryOverviewStyleMasks:
            return MemoryLayout<Float>.stride
        case .geometryLineStyles:
            return MemoryLayout<TileLineStyle>.stride
        case .glyphRunVertices, .poiIconRunVertices, .roadLabelGlyphVertices:
            return MemoryLayout<LabelVertex>.stride
        case .geometryIndices, .extrudedIndices:
            return nil
        }
    }

    private static func appendGeometryLayer(_ layerID: TileArenaGeometryLayerID,
                                            to slots: inout [TileArenaSlot]) {
        slots.append(.geometryVertices(layerID))
        slots.append(.geometryIndices(layerID))
        slots.append(.geometryStyles(layerID))
        slots.append(.geometryOverviewStyleMasks(layerID))
        slots.append(.geometryLineStyles(layerID))
    }
}
