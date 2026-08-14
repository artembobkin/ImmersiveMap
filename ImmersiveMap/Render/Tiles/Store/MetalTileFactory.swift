// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import MetalKit

/// Turns a parsed tile into GPU state. Every buffer of the tile lives in one
/// backing allocation whose byte layout is the canonical `TileArenaSchema`
/// slot sequence, so a freshly parsed tile and a disk-cached arena image
/// produce identical arenas: the parse path writes the plan into the buffer,
/// the cache path copies (or MTLIO-loads) the stored blob, and both rebuild
/// the same `TileBufferView`s from the span table. The reader verifies every
/// span take against the schema slot it expects, so a traversal that drifts
/// from the schema fails instead of binding bytes to the wrong destination.
/// `@unchecked Sendable`: both stored properties are immutable references to
/// thread-safe Metal objects, and concurrent tile loads already call
/// `makeTile` from independent tasks through the render store.
final class MetalTileFactory: @unchecked Sendable {
    private let metalDevice: MTLDevice
#if !targetEnvironment(simulator)
    /// Resolved at init on Metal 3 devices (see `sharedIOCommandQueue`): tile
    /// loads materialize concurrently from their own tasks, so lazy creation
    /// would race. The simulator SDK has no MTLIO surface at all.
    private let ioCommandQueue: MTLIOCommandQueue?
#endif

    init(metalDevice: MTLDevice) {
        self.metalDevice = metalDevice
#if !targetEnvironment(simulator)
        self.ioCommandQueue = MetalTileFactory.sharedIOCommandQueue(for: metalDevice)
#endif
    }

#if !targetEnvironment(simulator)
    private static let ioCommandQueueLock = NSLock()
    nonisolated(unsafe) private static var ioCommandQueuesByDevice: [ObjectIdentifier: MTLIOCommandQueue] = [:]

    /// One IO command queue per device, shared by every factory.
    ///
    /// The queue is a device-level object, and an app runs one engine, so
    /// per-factory queues bought nothing. They cost, though: each queue
    /// spawns its own IO threads and holds kernel-side resources for as long
    /// as it lives. A process that builds engines in a loop (the test suite
    /// creates dozens through `ImmersiveMapStillRecorder` and the video
    /// export; a host app that recreates its renderer does the same) piles
    /// those up, and past some count the IOGPU driver stops servicing
    /// submissions on freshly created queues entirely: loads park in
    /// `IOGPUIOCommandQueuePerformIO` and their completion handlers never
    /// run. Sharing keeps the count at one per device no matter how many
    /// engines come and go.
    private static func sharedIOCommandQueue(for metalDevice: MTLDevice) -> MTLIOCommandQueue? {
        guard MTLIOPreparedTileGeometryTransport.isSupported(metalDevice: metalDevice) else {
            return nil
        }
        let key = ObjectIdentifier(metalDevice)
        ioCommandQueueLock.lock()
        defer { ioCommandQueueLock.unlock() }
        if let existing = ioCommandQueuesByDevice[key] {
            return existing
        }
        let descriptor = MTLIOCommandQueueDescriptor()
        descriptor.type = .concurrent
        guard let queue = try? metalDevice.makeIOCommandQueue(descriptor: descriptor) else {
            return nil
        }
        ioCommandQueuesByDevice[key] = queue
        return queue
    }
#endif

    /// Whether this factory can DMA-load `.file` geometry blobs: Metal 3
    /// support and a successfully created IO command queue. The render store
    /// derives the geometry transport from this one answer, so a
    /// queue-creation failure degrades the whole session to the inline
    /// transport before any file entry exists, instead of saving entries no
    /// hit could ever load.
    var loadsFileBlobs: Bool {
#if targetEnvironment(simulator)
        return false
#else
        return ioCommandQueue != nil
#endif
    }

    /// nil when the backing allocation fails (memory pressure) or the arena
    /// traversal does not match the schema (a programming error, asserted):
    /// the caller fails the materialize so the load records a retryable
    /// failure instead of caching a permanently blank tile.
    ///
    /// `plan` is the arena plan of this exact tile when the caller already
    /// built one (the loader shares it with the disk save); nil computes it.
    func makeTile(from preparedTile: PreparedTileCPU,
                  plan providedPlan: TileArenaImagePlan? = nil) -> MetalTile? {
        let plan = providedPlan ?? TileArenaImageMath.plan(for: preparedTile)

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
            // The plan and the reader both walk the schema's slot sequence,
            // so a mismatch here is a programming error, but failing into
            // the retry path beats publishing a blank tile.
            assertionFailure("The arena reader disagreed with the schema slot sequence")
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
    /// from the blob (CPU copy for inline blobs, `MTLIOCommandQueue` load for
    /// file blobs), verifies the file blob against the checksum stored in the
    /// metadata, and rebuilds the buffer views from the span table.
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
            case .file(let url, let format, let checksum):
#if targetEnvironment(simulator)
                // The simulator writes and reads inline entries only (its own
                // cache namespace); a file blob here is foreign data.
                _ = url
                _ = format
                _ = checksum
                return .imageUnreadable
#else
                guard let queue = ioCommandQueue else {
                    // Unreachable through production wiring: the store selects
                    // the file transport from `loadsFileBlobs`, so a session
                    // without a queue never sees file entries. Kept transient
                    // so an exotic caller cannot delete a healthy entry.
                    return .allocationFailed
                }
                guard await loadFileBlob(from: url,
                                         format: format,
                                         into: buffer,
                                         byteCount: image.arenaByteCount,
                                         queue: queue) else {
                    return .imageUnreadable
                }
                // A .complete status proves the DMA finished, not that these
                // are the bytes the metadata describes: a bit-flipped or
                // truncated container still loads "complete", and a crash (or
                // a second engine writing the same namespace) can pair old
                // metadata with a newer container. The checksum stored in the
                // metadata binds the pair; a mismatch fails into removal and
                // a clean re-parse.
                let loadedChecksum = PreparedTileBlobChecksum.checksum(
                    UnsafeRawBufferPointer(start: buffer.contents(), count: image.arenaByteCount)
                )
                guard loadedChecksum == checksum else {
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

    /// Rebuilds `TileBuffers` by walking the span table against the schema's
    /// slot sequence (derived from the same metadata). nil when the table
    /// does not match (wrong span count, out-of-bounds span, wrong stride,
    /// a take out of schema order): cached tables are untrusted input, and
    /// the parse path shares the check as its final defense.
    private static func buildTileBuffers(spans: [TileArenaSpan],
                                         backingBuffer: MTLBuffer?,
                                         full: PreparedTileArenaImage.TextLabelSetMeta,
                                         reduced: PreparedTileArenaImage.TextLabelSetMeta,
                                         minimal: PreparedTileArenaImage.TextLabelSetMeta,
                                         roadLabels: PreparedTileArenaImage.RoadLabelsMeta) -> TileBuffers? {
        let expectedSlots = TileArenaSchema.slots(full: TileArenaSchema.runCounts(of: full),
                                                  reduced: TileArenaSchema.runCounts(of: reduced),
                                                  minimal: TileArenaSchema.runCounts(of: minimal))
        var cursor = SpanCursor(spans: spans,
                                expectedSlots: expectedSlots,
                                backingBuffer: backingBuffer)

        let ground = takeGeometryLayer(.ground, cursor: &cursor)
        let roads = RoadStructureBuckets(
            tunnel: takeRoadPhases(.tunnel, cursor: &cursor),
            ground: takeRoadPhases(.ground, cursor: &cursor),
            bridge: takeRoadPhases(.bridge, cursor: &cursor)
        )
        let bridgeOverlay = takeGeometryLayer(.bridgeOverlay, cursor: &cursor)

        let extrudedVertices = cursor.takeView(.extrudedVertices)
        let extrudedIndices = cursor.takeIndexView(.extrudedIndices)
        let extruded = TileBuffers.Extruded(vertices: extrudedVertices,
                                            indices: extrudedIndices.view,
                                            styles: cursor.takeView(.extrudedStyles),
                                            indexType: extrudedIndices.indexType)

        let textLabels = TileBuffers.TextLabels(full: takeTextLabelSet(full, tier: .full, cursor: &cursor),
                                                reduced: takeTextLabelSet(reduced, tier: .reduced, cursor: &cursor),
                                                minimal: takeTextLabelSet(minimal, tier: .minimal, cursor: &cursor))
        let roadGlyphVertices = cursor.takeView(.roadLabelGlyphVertices)
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

    private static func takeGeometryLayer(_ layerID: TileArenaGeometryLayerID,
                                          cursor: inout SpanCursor) -> TileBuffers.GeometryLayer {
        let vertices = cursor.takeView(.geometryVertices(layerID))
        let indices = cursor.takeIndexView(.geometryIndices(layerID))
        return TileBuffers.GeometryLayer(vertices: vertices,
                                         indices: indices.view,
                                         styles: cursor.takeView(.geometryStyles(layerID)),
                                         overviewStyleMask: cursor.takeView(.geometryOverviewStyleMasks(layerID)),
                                         lineWidthPoints: cursor.takeView(.geometryLineWidthPoints(layerID)),
                                         indexType: indices.indexType)
    }

    private static func takeRoadPhases(_ structureKind: TileMvtParser.RoadStructureKind,
                                       cursor: inout SpanCursor) -> RoadGeometryPhases<TileBuffers.GeometryLayer> {
        RoadGeometryPhases(shadow: takeGeometryLayer(.road(structureKind, .shadow), cursor: &cursor),
                           casing: takeGeometryLayer(.road(structureKind, .casing), cursor: &cursor),
                           fill: takeGeometryLayer(.road(structureKind, .fill), cursor: &cursor),
                           detail: takeGeometryLayer(.road(structureKind, .detail), cursor: &cursor),
                           overlay: takeGeometryLayer(.road(structureKind, .overlay), cursor: &cursor))
    }

    private static func takeTextLabelSet(_ meta: PreparedTileArenaImage.TextLabelSetMeta,
                                         tier: BaseLabelDetailTier,
                                         cursor: inout SpanCursor) -> TileBuffers.TextLabelSet {
        let glyphRuns = meta.glyphRunStyles.enumerated().map { run, style in
            LabelsByStyleRun(style: style,
                             localGlyphVertices: cursor.takeView(.glyphRunVertices(tier: tier, run: run)))
        }
        let poiIconRuns = meta.poiIconRunStyles.enumerated().map { run, style in
            PoiIconRunBuffer(style: style,
                             localVertices: cursor.takeView(.poiIconRunVertices(tier: tier, run: run)))
        }
        return TileBuffers.TextLabelSet(placementInputs: meta.placementInputs,
                                        labelsByStyleRuns: glyphRuns,
                                        poiIconRuns: poiIconRuns)
    }

    /// Sequential reader over the span table, pinned to the schema's slot
    /// sequence: every take names the slot it is reading for and the cursor
    /// verifies the claim, so bytes can only bind to the destination the
    /// schema says they belong to. Any violation (a take out of order, a span
    /// outside the arena, a stride mismatch) latches `failed`; the builder
    /// checks `isConsistent` once at the end so the traversal stays linear.
    private struct SpanCursor {
        private let spans: [TileArenaSpan]
        private let expectedSlots: [TileArenaSlot]
        private let backingBuffer: MTLBuffer?
        private var index = 0
        private var failed = false

        init(spans: [TileArenaSpan],
             expectedSlots: [TileArenaSlot],
             backingBuffer: MTLBuffer?) {
            self.spans = spans
            self.expectedSlots = expectedSlots
            self.backingBuffer = backingBuffer
        }

        var isConsistent: Bool {
            failed == false && index == spans.count && index == expectedSlots.count
        }

        mutating func takeView(_ slot: TileArenaSlot) -> TileBufferView? {
            guard let span = takeSpan(claiming: slot) else {
                return nil
            }
            guard let elementStride = TileArenaSchema.elementStride(of: slot),
                  span.indexWidth == nil else {
                failed = true
                return nil
            }
            return makeView(from: span, elementStride: elementStride)
        }

        mutating func takeIndexView(_ slot: TileArenaSlot) -> (view: TileBufferView?, indexType: MTLIndexType) {
            guard let span = takeSpan(claiming: slot) else {
                return (nil, .uint32)
            }
            guard TileArenaSchema.elementStride(of: slot) == nil,
                  let indexWidth = span.indexWidth else {
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

        private mutating func takeSpan(claiming slot: TileArenaSlot) -> TileArenaSpan? {
            guard index < spans.count,
                  index < expectedSlots.count,
                  expectedSlots[index] == slot else {
                failed = true
                return nil
            }
            let span = spans[index]
            index += 1
            return span
        }

        private mutating func makeView(from span: TileArenaSpan,
                                       elementStride: Int) -> TileBufferView? {
            guard span.elementCount > 0 else {
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
                              format: PreparedTileFileBlobFormat,
                              into buffer: MTLBuffer,
                              byteCount: Int,
                              queue: MTLIOCommandQueue) async -> Bool {
        let fileHandle: MTLIOFileHandle?
        switch format {
        case .raw:
            fileHandle = try? metalDevice.makeIOFileHandle(url: url)
        case .lzfseContainer:
            fileHandle = try? metalDevice.makeIOFileHandle(url: url, compressionMethod: .lzfse)
        }
        guard let fileHandle else {
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
