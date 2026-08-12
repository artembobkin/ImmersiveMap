// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Element width of an index span inside a tile's arena image. Mirrors
/// `MTLIndexType` without importing Metal, so the value can travel through
/// the disk codec (the `Tile` domain stays free of Metal types).
enum TileArenaIndexWidth: UInt8, Codable, Sendable {
    case uint16 = 0
    case uint32 = 1
}

/// One span of a tile's arena image, in canonical traversal order.
/// `byteCount` is the unpadded content size; the next span starts at the
/// next `TileArenaImageMath.spanAlignment` boundary after it.
struct TileArenaSpan: Equatable, Sendable {
    let byteOffset: Int
    let byteCount: Int
    let elementCount: Int
    /// Set for index spans only: records the narrowing decision so a cached
    /// image reproduces it without re-deriving anything.
    let indexWidth: TileArenaIndexWidth?
}

/// The byte-exact plan of one tile's arena: every GPU-bound array of
/// `PreparedTileCPU` laid out in the canonical traversal order with
/// 256-byte-aligned spans and 16-bit index narrowing already applied.
///
/// This is the single source of truth shared by `MetalTileFactory` (which
/// writes the plan straight into the tile's backing `MTLBuffer`) and the
/// prepared-tile disk codec (which writes the identical bytes into the cached
/// geometry blob), so a cached blob can be copied, or DMA-loaded, into a
/// fresh arena without any per-array decoding.
struct TileArenaImagePlan {
    enum Payload {
        case tileVertices([TileVertexIn])
        case extrudedVertices([TileMvtParser.ExtrudedVertexIn])
        case indicesUInt16([UInt16])
        case indicesUInt32([UInt32])
        case styles([TilePolygonStyle])
        case overviewStyleMasks([Float])
        case labelVertices([LabelVertex])
    }

    /// Payloads and spans run in lockstep: `payloads[i]` is described by
    /// `spans[i]`.
    let payloads: [Payload]
    let spans: [TileArenaSpan]
    let totalByteCount: Int
}

enum TileArenaImageMath {
    /// Every span starts 256-byte aligned: constant-address-space binds
    /// (the tile style and overview-mask pointers) require 256-byte
    /// setVertexBuffer offsets on Mac-family GPUs, and one alignment rule
    /// for every span keeps the plan and the write pass trivially symmetric.
    /// (Same rule as the per-route buffer offsets in RouteRenderSubsystem.)
    static let spanAlignment = 256

    static func alignedByteCount(_ byteCount: Int) -> Int {
        (byteCount + spanAlignment - 1) & ~(spanAlignment - 1)
    }

    /// Builds the canonical plan for one prepared tile. The traversal order
    /// is the format: ground, road buckets (tunnel, ground, bridge) each with
    /// phases (shadow, casing, fill, detail, overlay), bridge overlay,
    /// extruded, text label sets (full, reduced, minimal; glyph runs then POI
    /// icon runs), road label glyphs. Changing the order, the alignment, or
    /// the narrowing rule is a prepared-cache format change: bump
    /// `PreparedTileDiskCaching.preparedFormatVersion`.
    static func plan(for preparedTile: PreparedTileCPU) -> TileArenaImagePlan {
        var builder = PlanBuilder()

        appendGeometryLayer(preparedTile.ground, to: &builder)
        for bucket in preparedTile.roads.drawOrderBuckets {
            for phase in bucket.drawOrderLayers {
                appendGeometryLayer(phase, to: &builder)
            }
        }
        appendGeometryLayer(preparedTile.bridgeOverlay, to: &builder)

        builder.append(.extrudedVertices(preparedTile.extruded.vertices))
        builder.appendIndices(preparedTile.extruded.indices,
                              vertexCount: preparedTile.extruded.vertices.count)
        builder.append(.styles(preparedTile.extruded.styles))

        for labelSet in [preparedTile.textLabels.full,
                         preparedTile.textLabels.reduced,
                         preparedTile.textLabels.minimal] {
            for run in labelSet.glyphRuns {
                builder.append(.labelVertices(run.localGlyphVertices))
            }
            for run in labelSet.poiIconRuns {
                builder.append(.labelVertices(run.localIconVertices))
            }
        }
        builder.append(.labelVertices(preparedTile.roadLabels.localGlyphVertices))

        return builder.finish()
    }

    /// Writes the plan's payloads into `base` at their span offsets. `base`
    /// must hold at least `totalByteCount` bytes; padding between spans is
    /// zero-filled so the image is deterministic byte for byte.
    static func writeBlob(plan: TileArenaImagePlan, into base: UnsafeMutableRawPointer) {
        if plan.totalByteCount > 0 {
            base.initializeMemory(as: UInt8.self, repeating: 0, count: plan.totalByteCount)
        }
        for (payload, span) in zip(plan.payloads, plan.spans) where span.byteCount > 0 {
            let destination = base.advanced(by: span.byteOffset)
            withPayloadBytes(payload) { bytes in
                destination.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            }
        }
    }

    private static func withPayloadBytes(_ payload: TileArenaImagePlan.Payload,
                                         _ body: (UnsafeRawBufferPointer) -> Void) {
        switch payload {
        case .tileVertices(let values):
            values.withUnsafeBytes(body)
        case .extrudedVertices(let values):
            values.withUnsafeBytes(body)
        case .indicesUInt16(let values):
            values.withUnsafeBytes(body)
        case .indicesUInt32(let values):
            values.withUnsafeBytes(body)
        case .styles(let values):
            values.withUnsafeBytes(body)
        case .overviewStyleMasks(let values):
            values.withUnsafeBytes(body)
        case .labelVertices(let values):
            values.withUnsafeBytes(body)
        }
    }

    private static func appendGeometryLayer(_ layer: PreparedTileCPU.GeometryLayer,
                                            to builder: inout PlanBuilder) {
        builder.append(.tileVertices(layer.vertices))
        builder.appendIndices(layer.indices, vertexCount: layer.vertices.count)
        builder.append(.styles(layer.styles))
        builder.append(.overviewStyleMasks(layer.overviewStyleMasks))
    }

    private struct PlanBuilder {
        private var payloads: [TileArenaImagePlan.Payload] = []
        private var spans: [TileArenaSpan] = []
        private var cursor = 0

        mutating func append(_ payload: TileArenaImagePlan.Payload) {
            let (byteCount, elementCount) = measure(payload)
            payloads.append(payload)
            spans.append(TileArenaSpan(byteOffset: cursor,
                                       byteCount: byteCount,
                                       elementCount: elementCount,
                                       indexWidth: nil))
            cursor += TileArenaImageMath.alignedByteCount(byteCount)
        }

        /// Applies the factory's 16-bit narrowing once, at plan time, and
        /// records the decision in the span.
        mutating func appendIndices(_ indices: [UInt32], vertexCount: Int) {
            if let narrowed = IndexStorageMath.narrowedIndices(indices, vertexCount: vertexCount) {
                let byteCount = narrowed.count * MemoryLayout<UInt16>.stride
                payloads.append(.indicesUInt16(narrowed))
                spans.append(TileArenaSpan(byteOffset: cursor,
                                           byteCount: byteCount,
                                           elementCount: narrowed.count,
                                           indexWidth: .uint16))
                cursor += TileArenaImageMath.alignedByteCount(byteCount)
            } else {
                let byteCount = indices.count * MemoryLayout<UInt32>.stride
                payloads.append(.indicesUInt32(indices))
                spans.append(TileArenaSpan(byteOffset: cursor,
                                           byteCount: byteCount,
                                           elementCount: indices.count,
                                           indexWidth: .uint32))
                cursor += TileArenaImageMath.alignedByteCount(byteCount)
            }
        }

        func finish() -> TileArenaImagePlan {
            TileArenaImagePlan(payloads: payloads, spans: spans, totalByteCount: cursor)
        }

        private func measure(_ payload: TileArenaImagePlan.Payload) -> (byteCount: Int, elementCount: Int) {
            switch payload {
            case .tileVertices(let values):
                return (values.count * MemoryLayout<TileVertexIn>.stride, values.count)
            case .extrudedVertices(let values):
                return (values.count * MemoryLayout<TileMvtParser.ExtrudedVertexIn>.stride, values.count)
            case .indicesUInt16(let values):
                return (values.count * MemoryLayout<UInt16>.stride, values.count)
            case .indicesUInt32(let values):
                return (values.count * MemoryLayout<UInt32>.stride, values.count)
            case .styles(let values):
                return (values.count * MemoryLayout<TilePolygonStyle>.stride, values.count)
            case .overviewStyleMasks(let values):
                return (values.count * MemoryLayout<Float>.stride, values.count)
            case .labelVertices(let values):
                return (values.count * MemoryLayout<LabelVertex>.stride, values.count)
            }
        }
    }
}
