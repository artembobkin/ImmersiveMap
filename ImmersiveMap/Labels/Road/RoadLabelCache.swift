// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

//
//  RoadLabelCache.swift
//  ImmersiveMap
//

import Foundation
import Metal
import simd

struct RoadLabelEntry {
    let entryKey: UInt64
    let sourceKey: UInt64
    let text: String
    let style: LabelTextStyle
    let pointInputs: [TilePointInput]
    let canonicalPoints: [SIMD2<Float>]
    let canonicalTotalLength: Float
    let anchors: [RoadLabelAnchor]
    let templateVertices: [LabelVertex]
    let glyphBounds: [SIMD4<Float>]
    let labelSize: SIMD2<Float>
    let isRetained: UInt8
    let sourcePriority: Int
}

final class RoadLabelTileRecord {
    let ownerKey: VisibleTile
    var metalTileIdentity: ObjectIdentifier
    var isRetained: UInt8
    var sourcePriority: Int
    var visibleTileIndex: UInt32
    var instanceStart: Int = 0

    let labelStyle: LabelTextStyle
    private(set) var entries: [RoadLabelEntry]
    let instanceKeys: [UInt64]
    private(set) var instanceRetainedFlags: [UInt8]
    let instanceLabelSizes: [SIMD2<Float>]
    // Глифы инстанса лежат в glyphInputs непрерывно (порядок построения
    // makeTileRecord) — диапазоны позволяют читать коллизионные AABB инстанса
    // из GPU-буферов без CPU-репроекции.
    let instanceGlyphRanges: [Range<Int>]
    let instanceAnchorOrdinals: [UInt32]
    private(set) var instanceSourcePriorities: [Int]

    let pathPointCount: Int
    let glyphCount: Int
    let localGlyphVertexCount: Int

    let localGlyphVerticesBuffer: MTLBuffer?
    let pathInputsBuffer: MTLBuffer?
    let pathRangesBuffer: MTLBuffer?
    let anchorsBuffer: MTLBuffer?
    let glyphInputsBuffer: MTLBuffer?
    let collisionInputsBuffer: MTLBuffer?

    // Слоты, в которые хотя бы раз кодировался placement-компьют этого рекорда:
    // до первого прохода GPU slot-буферы содержат мусор и читать их нельзя.
    // Переиспользование слота кадром N означает завершение кадра N-slots —
    // прочитанные данные всегда с завершённого кадра той же раскладки глифов.
    private var placementEncodedSlots: [Bool]

    private let visibleTileIndexBufferStore: DynamicMetalBuffer<UInt32>
    private(set) var visibleTileIndexBuffer: MTLBuffer
    private let placementBufferStore: FrameSlottedDynamicMetalBuffer<RoadGlyphPlacementOutput>
    private let runtimeMetaBufferStore: FrameSlottedDynamicMetalBuffer<LabelRuntimeMeta>
    private let pathPointScreenBufferStore: FrameSlottedDynamicMetalBuffer<ScreenPointOutput>
    private let glyphScreenPointBufferStore: FrameSlottedDynamicMetalBuffer<ScreenPointOutput>
    private let collisionAabbBufferStore: FrameSlottedDynamicMetalBuffer<RoadGlyphCollisionOutput>

    init(metalDevice: MTLDevice,
         ownerKey: VisibleTile,
         metalTileIdentity: ObjectIdentifier,
         isRetained: UInt8,
         sourcePriority: Int,
         visibleTileIndex: UInt32,
         labelStyle: LabelTextStyle,
         entries: [RoadLabelEntry],
         instanceKeys: [UInt64],
         instanceRetainedFlags: [UInt8],
         instanceLabelSizes: [SIMD2<Float>],
         instanceGlyphRanges: [Range<Int>],
         instanceAnchorOrdinals: [UInt32],
         instanceSourcePriorities: [Int],
         pathInputs: [TilePointInput],
         pathRanges: [RoadPathRangeGpu],
         anchors: [RoadLabelAnchor],
         glyphInputs: [RoadGlyphInput],
         collisionInputs: [ScreenCollisionInput],
         localGlyphVerticesBuffer: MTLBuffer?,
         localGlyphVertexCount: Int) {
        self.ownerKey = ownerKey
        self.metalTileIdentity = metalTileIdentity
        self.isRetained = isRetained
        self.sourcePriority = sourcePriority
        self.visibleTileIndex = visibleTileIndex
        self.labelStyle = labelStyle
        self.entries = entries
        self.instanceKeys = instanceKeys
        self.instanceRetainedFlags = instanceRetainedFlags
        self.instanceLabelSizes = instanceLabelSizes
        self.instanceGlyphRanges = instanceGlyphRanges
        self.instanceAnchorOrdinals = instanceAnchorOrdinals
        self.instanceSourcePriorities = instanceSourcePriorities
        self.placementEncodedSlots = Array(repeating: false, count: InFlightFramePool.inFlightFramesCount)
        self.pathPointCount = pathInputs.count
        self.glyphCount = glyphInputs.count
        self.localGlyphVertexCount = localGlyphVertexCount
        self.localGlyphVerticesBuffer = localGlyphVerticesBuffer
        self.pathInputsBuffer = Self.makeBuffer(device: metalDevice, values: pathInputs)
        self.pathRangesBuffer = Self.makeBuffer(device: metalDevice, values: pathRanges)
        self.anchorsBuffer = Self.makeBuffer(device: metalDevice, values: anchors)
        self.glyphInputsBuffer = Self.makeBuffer(device: metalDevice, values: glyphInputs)
        self.collisionInputsBuffer = Self.makeBuffer(device: metalDevice, values: collisionInputs)
        self.visibleTileIndexBufferStore = DynamicMetalBuffer(metalDevice: metalDevice, options: [.storageModeShared])
        self.visibleTileIndexBuffer = visibleTileIndexBufferStore.buffer
        self.placementBufferStore = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                                   slotsCount: InFlightFramePool.inFlightFramesCount,
                                                                   options: [.storageModeShared])
        self.runtimeMetaBufferStore = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                                     slotsCount: InFlightFramePool.inFlightFramesCount,
                                                                     options: [.storageModeShared])
        self.pathPointScreenBufferStore = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                                         slotsCount: InFlightFramePool.inFlightFramesCount,
                                                                         options: [.storageModeShared])
        self.glyphScreenPointBufferStore = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                                          slotsCount: InFlightFramePool.inFlightFramesCount,
                                                                          options: [.storageModeShared])
        self.collisionAabbBufferStore = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                                       slotsCount: InFlightFramePool.inFlightFramesCount,
                                                                       options: [.storageModeShared])
        updateVisibleTileIndex(visibleTileIndex)
    }

    var hasRenderableGlyphs: Bool {
        glyphCount > 0 && localGlyphVerticesBuffer != nil && localGlyphVertexCount > 0
    }

    func updateVisibleTileIndex(_ value: UInt32) {
        visibleTileIndex = value
        visibleTileIndexBuffer = visibleTileIndexBufferStore.ensureCapacity(count: 1)
        var visibleIndex = value
        withUnsafeBytes(of: &visibleIndex) { bytes in
            visibleTileIndexBuffer.contents().copyMemory(from: bytes.baseAddress!,
                                                         byteCount: MemoryLayout<UInt32>.stride)
        }
    }

    func updateMetadata(isRetained: UInt8,
                        sourcePriority: Int) {
        self.isRetained = isRetained
        self.sourcePriority = sourcePriority
        if entries.isEmpty == false {
            entries = entries.map { entry in
                RoadLabelEntry(entryKey: entry.entryKey,
                               sourceKey: entry.sourceKey,
                               text: entry.text,
                               style: entry.style,
                               pointInputs: entry.pointInputs,
                               canonicalPoints: entry.canonicalPoints,
                               canonicalTotalLength: entry.canonicalTotalLength,
                               anchors: entry.anchors,
                               templateVertices: entry.templateVertices,
                               glyphBounds: entry.glyphBounds,
                               labelSize: entry.labelSize,
                               isRetained: isRetained,
                               sourcePriority: sourcePriority)
            }
        }
        if instanceRetainedFlags.isEmpty == false {
            instanceRetainedFlags = Array(repeating: isRetained, count: instanceRetainedFlags.count)
        }
        if instanceSourcePriorities.isEmpty == false {
            instanceSourcePriorities = Array(repeating: sourcePriority, count: instanceSourcePriorities.count)
        }
    }

    func markPlacementEncoded(slot: Int) {
        guard placementEncodedSlots.indices.contains(slot) else {
            return
        }
        placementEncodedSlots[slot] = true
    }

    // Рекорд выпал из активных (near-camera кулл): prepareGPU перестаёт
    // кодировать его компьют, slot-буферы замораживаются. Сброс стампов не даёт
    // первому циклу после возврата читать позиции произвольной давности —
    // решения откладываются до свежих данных (механика pending-ретриггера).
    func invalidatePlacementData() {
        for index in placementEncodedSlots.indices {
            placementEncodedSlots[index] = false
        }
    }

    func hasPlacementData(slot: Int) -> Bool {
        placementEncodedSlots.indices.contains(slot) && placementEncodedSlots[slot]
    }

    // Рекорд пригоден для placement-компьюта (зеркалит guard prepareGPU):
    // ожидать данных от рекорда, который никогда не будет закодирован
    // (отказ аллокации MTLBuffer), нельзя — pending завис бы навсегда.
    var canEncodePlacements: Bool {
        pathPointCount > 0 && glyphCount > 0
            && pathInputsBuffer != nil && pathRangesBuffer != nil
            && anchorsBuffer != nil && glyphInputsBuffer != nil
            && collisionInputsBuffer != nil
    }

    func placementBuffer(slot: Int) -> MTLBuffer {
        placementBufferStore.ensureCapacity(slot: slot, count: max(1, glyphCount))
    }

    func runtimeMetaBuffer(slot: Int, meta: [LabelRuntimeMeta]) -> MTLBuffer {
        let buffer = runtimeMetaBufferStore.ensureCapacity(slot: slot, count: max(1, meta.count))
        guard meta.isEmpty == false else {
            return buffer
        }
        meta.withUnsafeBytes { bytes in
            buffer.contents().copyMemory(from: bytes.baseAddress!,
                                         byteCount: meta.count * MemoryLayout<LabelRuntimeMeta>.stride)
        }
        return buffer
    }

    func pathPointScreenBuffer(slot: Int) -> MTLBuffer {
        pathPointScreenBufferStore.ensureCapacity(slot: slot, count: max(1, pathPointCount))
    }

    func glyphScreenPointBuffer(slot: Int) -> MTLBuffer {
        glyphScreenPointBufferStore.ensureCapacity(slot: slot, count: max(1, glyphCount))
    }

    func collisionAabbBuffer(slot: Int) -> MTLBuffer {
        collisionAabbBufferStore.ensureCapacity(slot: slot, count: max(1, glyphCount))
    }

    private static func makeBuffer<T>(device: MTLDevice, values: [T]) -> MTLBuffer? {
        guard values.isEmpty == false else {
            return nil
        }
        return values.withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress!,
                              length: bytes.count,
                              options: [.storageModeShared])
        }
    }
}

final class RoadLabelCache {
    private let metalDevice: MTLDevice

    private var tileRecordsByOwnerKey: [VisibleTile: RoadLabelTileRecord] = [:]
    private var ownerOrder: [VisibleTile] = []

    private(set) var roadLabelStyle: LabelTextStyle?
    private(set) var instanceKeys: [UInt64] = []
    private(set) var instanceRetainedFlags: [UInt8] = []
    private(set) var instanceLabelSizes: [SIMD2<Float>] = []

    var entries: [RoadLabelEntry] {
        orderedTileRecords.flatMap(\.entries)
    }

    // Материализовано: состав меняется только в synchronize/evict, а читается
    // это свойство в нескольких горячих точках каждого кадра — computed-версия
    // делала dictionary-lookup на тайл и аллоцировала массив на каждое обращение.
    private(set) var orderedTileRecords: [RoadLabelTileRecord] = []

    init(metalDevice: MTLDevice,
         textRenderer _: TextRenderer) {
        self.metalDevice = metalDevice
    }

    func rebuild(trackedPlaceTiles: [PlaceTileRetantionTracker.TrackedPlaceTile],
                 tileIndexAllocator: VisibleTileIndexAllocator,
                 center: Center,
                 centerZoom: Int,
                 renderSurfaceMode: ViewMode) {
        synchronize(sourceEntries: BaseLabelSourceEntry.build(from: trackedPlaceTiles,
                                                              center: center,
                                                              centerZoom: centerZoom,
                                                              renderSurfaceMode: renderSurfaceMode),
                    tileIndexAllocator: tileIndexAllocator,
                    trackedTilesChanged: true,
                    projectionChanged: true)
    }

    func rebuild(sourceEntries: [BaseLabelSourceEntry],
                 tileIndexAllocator: VisibleTileIndexAllocator) {
        synchronize(sourceEntries: sourceEntries,
                    tileIndexAllocator: tileIndexAllocator,
                    trackedTilesChanged: true,
                    projectionChanged: true)
    }

    func synchronize(sourceEntries: [BaseLabelSourceEntry],
                     tileIndexAllocator: VisibleTileIndexAllocator,
                     trackedTilesChanged: Bool,
                     projectionChanged: Bool) {
        if trackedTilesChanged {
            synchronizeTrackedTiles(sourceEntries: sourceEntries,
                                    tileIndexAllocator: tileIndexAllocator)
            orderedTileRecords = ownerOrder.compactMap { tileRecordsByOwnerKey[$0] }
            rebuildAggregatedState()
        } else if projectionChanged {
            updateVisibleTileIndices(sourceEntries: sourceEntries,
                                     tileIndexAllocator: tileIndexAllocator)
        }

        roadLabelStyle = orderedTileRecords.first?.labelStyle
    }

    func evict() {
        tileRecordsByOwnerKey.removeAll(keepingCapacity: false)
        ownerOrder.removeAll(keepingCapacity: false)
        orderedTileRecords.removeAll(keepingCapacity: false)
        roadLabelStyle = nil
        instanceKeys.removeAll(keepingCapacity: false)
        instanceRetainedFlags.removeAll(keepingCapacity: false)
        instanceLabelSizes.removeAll(keepingCapacity: false)
    }

    private func synchronizeTrackedTiles(sourceEntries: [BaseLabelSourceEntry],
                                         tileIndexAllocator: VisibleTileIndexAllocator) {
        let nextOwnerKeys = sourceEntries.map(\.ownerKey)
        let nextOwnerKeySet = Set(nextOwnerKeys)
        let removedOwnerKeys = ownerOrder.filter { nextOwnerKeySet.contains($0) == false }
        for removedOwnerKey in removedOwnerKeys {
            tileRecordsByOwnerKey.removeValue(forKey: removedOwnerKey)
        }

        for sourceEntry in sourceEntries {
            let visibleTileIndex = UInt32(tileIndexAllocator.tileIndex(for: sourceEntry.ownerKey))
            upsertTileRecord(sourceEntry, visibleTileIndex: visibleTileIndex)
        }

        ownerOrder = nextOwnerKeys
    }

    private func updateVisibleTileIndices(sourceEntries: [BaseLabelSourceEntry],
                                          tileIndexAllocator: VisibleTileIndexAllocator) {
        for sourceEntry in sourceEntries {
            guard let record = tileRecordsByOwnerKey[sourceEntry.ownerKey] else {
                continue
            }
            let visibleTileIndex = UInt32(tileIndexAllocator.tileIndex(for: sourceEntry.ownerKey))
            record.updateVisibleTileIndex(visibleTileIndex)
        }
    }

    private func upsertTileRecord(_ sourceEntry: BaseLabelSourceEntry,
                                  visibleTileIndex: UInt32) {
        let ownerKey = sourceEntry.ownerKey
        let metalTileIdentity = sourceEntry.metalTileIdentity
        let isRetained: UInt8 = sourceEntry.isRetained ? 1 : 0
        let sourcePriority = BaseLabelSourceEntry.priorityRank(for: sourceEntry)

        if let existingRecord = tileRecordsByOwnerKey[ownerKey] {
            let payloadChanged = existingRecord.metalTileIdentity != metalTileIdentity
            if payloadChanged == false {
                existingRecord.metalTileIdentity = metalTileIdentity
                existingRecord.updateMetadata(isRetained: isRetained,
                                              sourcePriority: sourcePriority)
                existingRecord.updateVisibleTileIndex(visibleTileIndex)
                return
            }
        }

        tileRecordsByOwnerKey[ownerKey] = makeTileRecord(sourceEntry: sourceEntry,
                                                         visibleTileIndex: visibleTileIndex)
    }

    private func rebuildAggregatedState() {
        instanceKeys.removeAll(keepingCapacity: true)
        instanceRetainedFlags.removeAll(keepingCapacity: true)
        instanceLabelSizes.removeAll(keepingCapacity: true)

        var runningInstanceStart = 0
        for ownerKey in ownerOrder {
            guard let record = tileRecordsByOwnerKey[ownerKey] else {
                continue
            }
            record.instanceStart = runningInstanceStart
            instanceKeys.append(contentsOf: record.instanceKeys)
            instanceRetainedFlags.append(contentsOf: record.instanceRetainedFlags)
            instanceLabelSizes.append(contentsOf: record.instanceLabelSizes)
            runningInstanceStart += record.instanceKeys.count
        }
    }

    private func makeTileRecord(sourceEntry: BaseLabelSourceEntry,
                                visibleTileIndex: UInt32) -> RoadLabelTileRecord {
        let roadLabels = sourceEntry.metalTile.tileBuffers.roadLabels
        let style = roadLabels.labelStyle ?? Self.fallbackStyle
        let isRetained: UInt8 = sourceEntry.isRetained ? 1 : 0
        let sourcePriority = BaseLabelSourceEntry.priorityRank(for: sourceEntry)

        var entries: [RoadLabelEntry] = []
        var instanceKeys: [UInt64] = []
        var instanceRetainedFlags: [UInt8] = []
        var instanceLabelSizes: [SIMD2<Float>] = []
        var instanceGlyphRanges: [Range<Int>] = []
        var instanceAnchorOrdinals: [UInt32] = []
        var instanceSourcePriorities: [Int] = []
        var pathInputs: [TilePointInput] = []
        var pathRanges: [RoadPathRangeGpu] = []
        var anchors: [RoadLabelAnchor] = []
        var glyphInputs: [RoadGlyphInput] = []
        var collisionInputs: [ScreenCollisionInput] = []

        entries.reserveCapacity(roadLabels.pathRanges.count)
        for pathRange in roadLabels.pathRanges {
            let labelIndex = pathRange.labelIndex
            guard labelIndex >= 0,
                  labelIndex < roadLabels.pathLabels.count,
                  labelIndex < roadLabels.glyphBoundRanges.count,
                  labelIndex < roadLabels.sizes.count,
                  labelIndex < roadLabels.anchorRanges.count else {
                continue
            }

            let pointRangeEnd = pathRange.start + pathRange.count
            guard pathRange.count > 1,
                  pathRange.start >= 0,
                  pointRangeEnd <= roadLabels.pathInputs.count else {
                continue
            }

            let localPathInputs = roadLabels.pathInputs[pathRange.start..<pointRangeEnd].map { input -> TilePointInput in
                var updated = input
                updated.tileSlotIndex = 0
                return updated
            }
            let canonicalPoints = localPathInputs.map(Self.makeCanonicalPoint)
            let canonicalTotalLength = Self.totalLength(points: canonicalPoints)
            guard canonicalTotalLength > 0 else {
                continue
            }

            let glyphBoundRange = roadLabels.glyphBoundRanges[labelIndex]
            let glyphBoundEnd = glyphBoundRange.start + glyphBoundRange.count
            guard glyphBoundRange.count > 0,
                  glyphBoundRange.start >= 0,
                  glyphBoundEnd <= roadLabels.glyphBounds.count else {
                continue
            }
            let glyphBounds = Array(roadLabels.glyphBounds[glyphBoundRange.start..<glyphBoundEnd])

            let anchorRange = roadLabels.anchorRanges[labelIndex]
            let anchorEnd = anchorRange.start + anchorRange.count
            guard anchorRange.count > 0,
                  anchorRange.start >= 0,
                  anchorEnd <= roadLabels.anchors.count else {
                continue
            }
            let localPathIndex = UInt32(pathRanges.count)
            let entryKey = Self.makeEntryKey(ownerKey: sourceEntry.ownerKey,
                                             sourceKey: roadLabels.pathLabels[labelIndex].key,
                                             labelIndex: labelIndex,
                                             pathRange: pathRange)
            let labelSize = roadLabels.sizes[labelIndex]
            let roadPathLabel = roadLabels.pathLabels[labelIndex]
            let entryAnchors = Array(roadLabels.anchors[anchorRange.start..<anchorEnd])

            entries.append(RoadLabelEntry(entryKey: entryKey,
                                          sourceKey: roadPathLabel.key,
                                          text: roadPathLabel.text,
                                          style: style,
                                          pointInputs: localPathInputs,
                                          canonicalPoints: canonicalPoints,
                                          canonicalTotalLength: canonicalTotalLength,
                                          anchors: entryAnchors,
                                          templateVertices: [],
                                          glyphBounds: glyphBounds,
                                          labelSize: labelSize,
                                          isRetained: isRetained,
                                          sourcePriority: sourcePriority))

            let pathStart = pathInputs.count
            pathInputs.append(contentsOf: localPathInputs)
            pathRanges.append(RoadPathRangeGpu(start: UInt32(pathStart),
                                               count: UInt32(localPathInputs.count)))

            for anchor in entryAnchors {
                let instanceIndex = UInt32(instanceKeys.count)
                let instanceKey = Self.makeInstanceKey(entryKey: entryKey,
                                                       anchorOrdinal: anchor.anchorOrdinal)
                instanceKeys.append(instanceKey)
                instanceRetainedFlags.append(isRetained)
                instanceLabelSizes.append(labelSize)
                anchors.append(RoadLabelAnchor(pathIndex: localPathIndex,
                                               segmentIndex: anchor.segmentIndex,
                                               t: anchor.t,
                                               distanceAlongPath: anchor.distanceAlongPath,
                                               anchorOrdinal: anchor.anchorOrdinal))

                let labelMinY = glyphBounds.reduce(Float.greatestFiniteMagnitude) { min($0, $1.z) }
                let labelMaxY = glyphBounds.reduce(-Float.greatestFiniteMagnitude) { max($0, $1.w) }
                let labelCenterY = (labelMinY + labelMaxY) * 0.5
                let instanceGlyphStart = glyphInputs.count
                instanceAnchorOrdinals.append(anchor.anchorOrdinal)
                instanceSourcePriorities.append(sourcePriority)

                for glyphBounds in glyphBounds {
                    let glyphCenter = (glyphBounds.x + glyphBounds.y) * 0.5
                    glyphInputs.append(RoadGlyphInput(pathIndex: localPathIndex,
                                                      instanceIndex: instanceIndex,
                                                      labelInstanceIndex: instanceIndex,
                                                      glyphCenter: glyphCenter,
                                                      labelCenterY: labelCenterY,
                                                      labelWidth: labelSize.x,
                                                      spacing: 0,
                                                      minLength: labelSize.x))
                    collisionInputs.append(ScreenCollisionInput(halfSize: SIMD2<Float>((glyphBounds.y - glyphBounds.x) * 0.5,
                                                                                       (glyphBounds.w - glyphBounds.z) * 0.5),
                                                               radius: 0,
                                                               shapeType: .rect))
                }
                instanceGlyphRanges.append(instanceGlyphStart..<glyphInputs.count)
            }
        }

        return RoadLabelTileRecord(metalDevice: metalDevice,
                                   ownerKey: sourceEntry.ownerKey,
                                   metalTileIdentity: sourceEntry.metalTileIdentity,
                                   isRetained: isRetained,
                                   sourcePriority: sourcePriority,
                                   visibleTileIndex: visibleTileIndex,
                                   labelStyle: style,
                                   entries: entries,
                                   instanceKeys: instanceKeys,
                                   instanceRetainedFlags: instanceRetainedFlags,
                                   instanceLabelSizes: instanceLabelSizes,
                                   instanceGlyphRanges: instanceGlyphRanges,
                                   instanceAnchorOrdinals: instanceAnchorOrdinals,
                                   instanceSourcePriorities: instanceSourcePriorities,
                                   pathInputs: pathInputs,
                                   pathRanges: pathRanges,
                                   anchors: anchors,
                                   glyphInputs: glyphInputs,
                                   collisionInputs: collisionInputs,
                                   localGlyphVerticesBuffer: roadLabels.localGlyphVerticesBuffer,
                                   localGlyphVertexCount: roadLabels.localGlyphVertexCount)
    }

    private static func totalLength(points: [SIMD2<Float>]) -> Float {
        guard points.count > 1 else {
            return 0
        }
        var total: Float = 0
        for index in 1..<points.count {
            total += simd_length(points[index] - points[index - 1])
        }
        return total
    }

    private static func makeCanonicalPoint(from input: TilePointInput) -> SIMD2<Float> {
        let zScale = powf(2.0, Float(input.tile.z))
        return SIMD2<Float>((Float(input.tile.x) + input.uv.x) / zScale,
                            (Float(input.tile.y) + input.uv.y) / zScale)
    }

    private static func makeEntryKey(ownerKey: VisibleTile,
                                     sourceKey: UInt64,
                                     labelIndex: Int,
                                     pathRange: RoadPathRange) -> UInt64 {
        var hasher = Hasher()
        hasher.combine(ownerKey.x)
        hasher.combine(ownerKey.y)
        hasher.combine(ownerKey.z)
        hasher.combine(ownerKey.loop)
        hasher.combine(sourceKey)
        hasher.combine(labelIndex)
        hasher.combine(pathRange.start)
        hasher.combine(pathRange.count)
        hasher.combine(pathRange.labelIndex)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }

    private static func makeInstanceKey(entryKey: UInt64,
                                        anchorOrdinal: UInt32) -> UInt64 {
        var hash = entryKey
        hash ^= UInt64(anchorOrdinal) &* 1469598103934665603
        return hash
    }

    private static let fallbackStyle = LabelTextStyle(key: 0,
                                                      fillColor: SIMD3<Float>(0.54, 0.54, 0.52),
                                                      strokeColor: SIMD3<Float>(0.54, 0.54, 0.52),
                                                      strokeWidthPx: 0.0,
                                                      sizePx: 36.0,
                                                      weight: .thin)
}
