// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

/// Turns a parsed tile into GPU state. Every buffer of the tile lives in one
/// backing allocation whose byte layout is the canonical
/// `TileArenaImageMath` plan, so a freshly parsed tile and a disk-cached
/// arena image produce identical arenas: the parse path writes the plan into
/// the buffer, the cache path copies (or MTLIO-loads) the stored blob, and
/// both rebuild the same `TileBufferView`s from the span table.
final class MetalTileFactory {
    private let metalDevice: MTLDevice
#if !targetEnvironment(simulator)
    /// Created once at init on devices whose transport writes file blobs:
    /// tile loads materialize concurrently from their own tasks, so lazy
    /// creation would race. nil where the transport is inline-only (no
    /// Metal 3) and on creation failure, which fails the materialize into
    /// the retry path. The simulator SDK has no MTLIO surface at all.
    private let ioCommandQueue: MTLIOCommandQueue?
#endif

    init(metalDevice: MTLDevice) {
        self.metalDevice = metalDevice
#if !targetEnvironment(simulator)
        if MTLIOPreparedTileGeometryTransport.isSupported(metalDevice: metalDevice) {
            let descriptor = MTLIOCommandQueueDescriptor()
            descriptor.type = .concurrent
            self.ioCommandQueue = try? metalDevice.makeIOCommandQueue(descriptor: descriptor)
        } else {
            self.ioCommandQueue = nil
        }
#endif
    }

    /// nil when the backing allocation fails (memory pressure): the caller
    /// fails the materialize so the load records a retryable failure instead
    /// of caching a permanently blank tile.
    func makeTile(from preparedTile: PreparedTileCPU) -> MetalTile? {
        let plan = TileArenaImageMath.plan(for: preparedTile)

        var backingBuffer: MTLBuffer?
        if plan.totalByteCount > 0 {
            guard let buffer = metalDevice.makeBuffer(length: plan.totalByteCount) else {
                return nil
            }
            TileArenaImageMath.writeBlob(plan: plan, into: buffer.contents())
            backingBuffer = buffer
        }

        guard let tileBuffers = Self.buildTileBuffers(
            spans: plan.spans,
            backingBuffer: backingBuffer,
            full: Self.textLabelSetMeta(from: preparedTile.textLabels.full),
            reduced: Self.textLabelSetMeta(from: preparedTile.textLabels.reduced),
            minimal: Self.textLabelSetMeta(from: preparedTile.textLabels.minimal),
            roadLabels: Self.roadLabelsMeta(from: preparedTile.roadLabels)
        ) else {
            // The plan and the builder share one traversal, so a mismatch here
            // is a programming error, but failing into the retry path beats
            // publishing a blank tile.
            assertionFailure("Arena plan and tile builder disagreed on the span traversal")
            return nil
        }
        return MetalTile(tile: preparedTile.tile, tileBuffers: tileBuffers)
    }

    /// Outcome of materializing a disk-cached arena image. The split matters
    /// for cleanup: an unreadable image is corrupt on disk and the caller
    /// removes it, while an allocation failure is transient memory pressure
    /// and the entry stays for the retry.
    enum ArenaImageMaterializeResult {
        case tile(MetalTile)
        case allocationFailed
        case imageUnreadable
    }

    /// Materializes a disk-cached arena image: allocates the arena, fills it
    /// from the blob (CPU copy for inline blobs, `MTLIOCommandQueue` load
    /// with hardware LZFSE for file blobs), and rebuilds the buffer views
    /// from the span table.
    func makeTile(fromImage image: PreparedTileArenaImage) async -> ArenaImageMaterializeResult {
        var backingBuffer: MTLBuffer?
        if image.arenaByteCount > 0 {
            guard let buffer = metalDevice.makeBuffer(length: image.arenaByteCount) else {
                return .allocationFailed
            }
            switch image.blob {
            case .inline(let blob):
                guard blob.count == image.arenaByteCount else {
                    return .imageUnreadable
                }
                blob.withUnsafeBytes { bytes in
                    buffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
                }
            case .file(let url):
#if targetEnvironment(simulator)
                // The simulator writes and reads inline entries only (its own
                // cache namespace); a file blob here is foreign data.
                _ = url
                return .imageUnreadable
#else
                guard let queue = ioCommandQueue else {
                    // Queue creation is device-level and should not fail on a
                    // Metal 3 device; treat it as transient rather than
                    // deleting a healthy cache entry.
                    return .allocationFailed
                }
                guard await loadFileBlob(from: url,
                                         into: buffer,
                                         byteCount: image.arenaByteCount,
                                         queue: queue) else {
                    return .imageUnreadable
                }
#endif
            }
            backingBuffer = buffer
        } else if case .inline(let blob) = image.blob, blob.isEmpty == false {
            return .imageUnreadable
        }

        guard let tileBuffers = Self.buildTileBuffers(spans: image.spans,
                                                      backingBuffer: backingBuffer,
                                                      full: image.textLabelsFull,
                                                      reduced: image.textLabelsReduced,
                                                      minimal: image.textLabelsMinimal,
                                                      roadLabels: image.roadLabels) else {
            return .imageUnreadable
        }
        return .tile(MetalTile(tile: image.tile, tileBuffers: tileBuffers))
    }

    // MARK: - Shared structure builder

    private static func textLabelSetMeta(from set: PreparedTileCPU.TextLabelSet)
        -> PreparedTileArenaImage.TextLabelSetMeta {
        PreparedTileArenaImage.TextLabelSetMeta(placementInputs: set.placementInputs,
                                                glyphRunStyles: set.glyphRuns.map(\.style),
                                                poiIconRunStyles: set.poiIconRuns.map(\.style))
    }

    private static func roadLabelsMeta(from roadLabels: PreparedTileCPU.RoadLabels)
        -> PreparedTileArenaImage.RoadLabelsMeta {
        PreparedTileArenaImage.RoadLabelsMeta(pathInputs: roadLabels.pathInputs,
                                              pathRanges: roadLabels.pathRanges,
                                              pathLabels: roadLabels.pathLabels,
                                              labelStyle: roadLabels.labelStyle,
                                              glyphBounds: roadLabels.glyphBounds,
                                              glyphBoundRanges: roadLabels.glyphBoundRanges,
                                              sizes: roadLabels.sizes,
                                              anchorRanges: roadLabels.anchorRanges,
                                              anchors: roadLabels.anchors)
    }

    /// Rebuilds `TileBuffers` by walking the span table in the same canonical
    /// order `TileArenaImageMath.plan` wrote it. nil when the table does not
    /// structurally match the metadata (wrong span count, out-of-bounds span,
    /// missing index width): cached tables are untrusted input.
    private static func buildTileBuffers(spans: [TileArenaSpan],
                                         backingBuffer: MTLBuffer?,
                                         full: PreparedTileArenaImage.TextLabelSetMeta,
                                         reduced: PreparedTileArenaImage.TextLabelSetMeta,
                                         minimal: PreparedTileArenaImage.TextLabelSetMeta,
                                         roadLabels: PreparedTileArenaImage.RoadLabelsMeta) -> TileBuffers? {
        var cursor = SpanCursor(spans: spans, backingBuffer: backingBuffer)

        let ground = takeGeometryLayer(&cursor)
        let roads = RoadStructureBuckets(
            tunnel: takeRoadPhases(&cursor),
            ground: takeRoadPhases(&cursor),
            bridge: takeRoadPhases(&cursor)
        )
        let bridgeOverlay = takeGeometryLayer(&cursor)

        let extrudedVertices = cursor.takeView(elementStride: MemoryLayout<TileMvtParser.ExtrudedVertexIn>.stride)
        let extrudedIndices = cursor.takeIndexView()
        let extruded = TileBuffers.Extruded(vertices: extrudedVertices,
                                            indices: extrudedIndices.view,
                                            styles: cursor.takeView(elementStride: MemoryLayout<TilePolygonStyle>.stride),
                                            indexType: extrudedIndices.indexType)

        let textLabels = TileBuffers.TextLabels(full: takeTextLabelSet(full, cursor: &cursor),
                                                reduced: takeTextLabelSet(reduced, cursor: &cursor),
                                                minimal: takeTextLabelSet(minimal, cursor: &cursor))
        let roadGlyphVertices = cursor.takeView(elementStride: MemoryLayout<LabelVertex>.stride)
        let roadLabelBuffers = TileBuffers.RoadLabels(pathInputs: roadLabels.pathInputs,
                                                      pathRanges: roadLabels.pathRanges,
                                                      pathLabels: roadLabels.pathLabels,
                                                      labelStyle: roadLabels.labelStyle,
                                                      localGlyphVertices: roadGlyphVertices,
                                                      glyphBounds: roadLabels.glyphBounds,
                                                      glyphBoundRanges: roadLabels.glyphBoundRanges,
                                                      sizes: roadLabels.sizes,
                                                      anchorRanges: roadLabels.anchorRanges,
                                                      anchors: roadLabels.anchors)

        guard cursor.isConsistent else {
            return nil
        }
        return TileBuffers(backingBuffer: backingBuffer,
                           ground: ground,
                           roads: roads,
                           bridgeOverlay: bridgeOverlay,
                           extruded: extruded,
                           textLabels: textLabels,
                           roadLabels: roadLabelBuffers)
    }

    private static func takeGeometryLayer(_ cursor: inout SpanCursor) -> TileBuffers.GeometryLayer {
        let vertices = cursor.takeView(elementStride: MemoryLayout<TilePipeline.VertexIn>.stride)
        let indices = cursor.takeIndexView()
        return TileBuffers.GeometryLayer(vertices: vertices,
                                         indices: indices.view,
                                         styles: cursor.takeView(elementStride: MemoryLayout<TilePolygonStyle>.stride),
                                         overviewStyleMask: cursor.takeView(elementStride: MemoryLayout<Float>.stride),
                                         indexType: indices.indexType)
    }

    private static func takeRoadPhases(_ cursor: inout SpanCursor) -> RoadGeometryPhases<TileBuffers.GeometryLayer> {
        RoadGeometryPhases(shadow: takeGeometryLayer(&cursor),
                           casing: takeGeometryLayer(&cursor),
                           fill: takeGeometryLayer(&cursor),
                           detail: takeGeometryLayer(&cursor),
                           overlay: takeGeometryLayer(&cursor))
    }

    private static func takeTextLabelSet(_ meta: PreparedTileArenaImage.TextLabelSetMeta,
                                         cursor: inout SpanCursor) -> TileBuffers.TextLabelSet {
        let glyphRuns = meta.glyphRunStyles.map { style in
            LabelsByStyleRun(style: style,
                             localGlyphVertices: cursor.takeView(elementStride: MemoryLayout<LabelVertex>.stride))
        }
        let poiIconRuns = meta.poiIconRunStyles.map { style in
            PoiIconRunBuffer(style: style,
                             localVertices: cursor.takeView(elementStride: MemoryLayout<LabelVertex>.stride))
        }
        return TileBuffers.TextLabelSet(placementInputs: meta.placementInputs,
                                        labelsByStyleRuns: glyphRuns,
                                        poiIconRuns: poiIconRuns)
    }

    /// Sequential reader over the span table. Any structural violation
    /// (running past the table, a span outside the arena, a missing index
    /// width) latches `failed`; the builder checks `isConsistent` once at
    /// the end so the traversal code stays linear.
    private struct SpanCursor {
        private let spans: [TileArenaSpan]
        private let backingBuffer: MTLBuffer?
        private var index = 0
        private var failed = false

        init(spans: [TileArenaSpan], backingBuffer: MTLBuffer?) {
            self.spans = spans
            self.backingBuffer = backingBuffer
        }

        var isConsistent: Bool {
            failed == false && index == spans.count
        }

        mutating func takeView(elementStride: Int) -> TileBufferView? {
            makeView(from: takeSpan(), elementStride: elementStride)
        }

        mutating func takeIndexView() -> (view: TileBufferView?, indexType: MTLIndexType) {
            guard let span = takeSpan() else {
                return (nil, .uint32)
            }
            guard let indexWidth = span.indexWidth else {
                failed = true
                return (nil, .uint32)
            }
            switch indexWidth {
            case .uint16:
                return (makeView(from: span, elementStride: MemoryLayout<UInt16>.stride), .uint16)
            case .uint32:
                return (makeView(from: span, elementStride: MemoryLayout<UInt32>.stride), .uint32)
            }
        }

        private mutating func takeSpan() -> TileArenaSpan? {
            guard index < spans.count else {
                failed = true
                return nil
            }
            let span = spans[index]
            index += 1
            return span
        }

        private mutating func makeView(from span: TileArenaSpan?,
                                       elementStride: Int) -> TileBufferView? {
            guard let span, span.elementCount > 0 else {
                return nil
            }
            // The stride check pins byteCount to the slot's element type, so a
            // corrupt element count cannot make a draw read past its span.
            guard let backingBuffer,
                  span.byteOffset >= 0,
                  span.byteCount == span.elementCount * elementStride,
                  span.byteOffset % TileArenaImageMath.spanAlignment == 0,
                  span.byteCount <= backingBuffer.length - span.byteOffset else {
                failed = true
                return nil
            }
            return TileBufferView(buffer: backingBuffer, offset: span.byteOffset, count: span.elementCount)
        }
    }

    // MARK: - MTLIO blob load

#if !targetEnvironment(simulator)
    private func loadFileBlob(from url: URL,
                              into buffer: MTLBuffer,
                              byteCount: Int,
                              queue: MTLIOCommandQueue) async -> Bool {
        guard let fileHandle = try? metalDevice.makeIOFileHandle(url: url, compressionMethod: .lzfse) else {
            return false
        }
        let ioCommandBuffer = queue.makeCommandBuffer()
        ioCommandBuffer.load(buffer,
                             offset: 0,
                             size: byteCount,
                             sourceHandle: fileHandle,
                             sourceHandleOffset: 0)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            ioCommandBuffer.addCompletedHandler { completedBuffer in
                continuation.resume(returning: completedBuffer.status == .complete)
            }
            ioCommandBuffer.commit()
        }
    }
#endif
}
