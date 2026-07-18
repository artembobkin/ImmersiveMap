// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  BaseLabelCache.swift
//  ImmersiveMap
//

import Metal
import simd

final class BaseLabelCache {
    private struct TileRecord {
        let ownerKey: VisibleTile
        var metalTileIdentity: ObjectIdentifier
        var labelDetailTier: BaseLabelDetailTier
        var isRetained: Bool
        var tileSlotIndex: UInt32
        var allocation: BaseLabelTileArena.Allocation
        var labelsCount: Int
        var labelKeys: [UInt64]
        var labelSortKeys: [Int]
        var labelCollisionPriorities: [Int]
        var labelSizes: [SIMD2<Float>]
        var labelMinCameraZooms: [Float]
        var labelsByStyleRuns: [LabelsByStyleRun]
        var poiIconRuns: [PoiIconRunBuffer]
    }

    private let arena = BaseLabelTileArena()
    private let labelRuntimeMetaBufferStore: FrameSlottedDynamicMetalBuffer<LabelRuntimeMeta>

    private var tileRecordsByOwnerKey: [VisibleTile: TileRecord] = [:]
    private var tilePointInputByOwnerKey: [VisibleTile: [TilePointInput]] = [:]
    private var ownerOrder: [VisibleTile] = []
    private var tileSlotVisibleTileIndices: [UInt32] = []
    private var labelRuntimeMetaData: [LabelRuntimeMeta] = []
    private var labelPresentationInputs: [BaseLabelPresentationInput] = []

    private(set) var baseLabelsDrawBatches: [BaseLabelDrawBatch] = []

    private(set) var labelInputsCount: Int = 0
    private(set) var activeLabelSpanCount: Int = 0
    private(set) var tilePointInputs: [TilePointInput] = []
    private(set) var labelCollisionAABBInputs: [ScreenCollisionCandidate] = []

    init(metalDevice: MTLDevice) {
        self.labelRuntimeMetaBufferStore = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                                          slotsCount: InFlightFramePool.inFlightFramesCount,
                                                                          options: [.storageModeShared])
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
            synchronizeTrackedTiles(sourceEntries)
            rebuildDrawBatches(sourceEntries)
            rebuildRuntimeMetaAndCollisionInputs(sourceEntries)
        }

        if trackedTilesChanged || projectionChanged {
            rebuildTileSlotVisibleTileIndices(sourceEntries, tileIndexAllocator: tileIndexAllocator)
        }
    }

    func reset() {
        arena.reset()
        tileRecordsByOwnerKey.removeAll(keepingCapacity: false)
        tilePointInputByOwnerKey.removeAll(keepingCapacity: false)
        ownerOrder.removeAll(keepingCapacity: false)
        tileSlotVisibleTileIndices.removeAll(keepingCapacity: false)
        baseLabelsDrawBatches.removeAll(keepingCapacity: false)
        tilePointInputs.removeAll(keepingCapacity: false)
        labelCollisionAABBInputs.removeAll(keepingCapacity: false)
        labelRuntimeMetaData.removeAll(keepingCapacity: false)
        labelPresentationInputs.removeAll(keepingCapacity: false)
        labelInputsCount = 0
        activeLabelSpanCount = 0
    }

    var tilePointSnapshot: TilePointToScreenPointSnapshot {
        TilePointToScreenPointSnapshot(pointInputs: tilePointInputs,
                                       tileSlotVisibleTileIndices: tileSlotVisibleTileIndices)
    }

    func labelRuntimeMetaBuffer(frameSlotIndex: Int) -> MTLBuffer {
        let buffer = labelRuntimeMetaBufferStore.ensureCapacity(slot: frameSlotIndex,
                                                                count: max(1, activeLabelSpanCount))
        uploadRuntimeMeta(into: buffer)
        return buffer
    }

    var presentationInputs: [BaseLabelPresentationInput] {
        labelPresentationInputs
    }

    func updateFadeAlphas(_ fadeAlphas: [Float], multiplier: Float = 1.0) {
        let count = min(labelRuntimeMetaData.count, fadeAlphas.count)
        if count > 0 {
            for index in 0..<count {
                labelRuntimeMetaData[index].fadeAlpha = fadeAlphas[index] * multiplier
            }
        }

        if count < labelRuntimeMetaData.count {
            for index in count..<labelRuntimeMetaData.count {
                labelRuntimeMetaData[index].fadeAlpha = 0
            }
        }
    }

    private func synchronizeTrackedTiles(_ sourceEntries: [BaseLabelSourceEntry]) {
        let nextOwnerKeys = sourceEntries.map(\.ownerKey)
        let nextOwnerKeySet = Set(nextOwnerKeys)
        let removedOwnerKeys = ownerOrder.filter { nextOwnerKeySet.contains($0) == false }
        for removedOwnerKey in removedOwnerKeys {
            removeTileRecord(for: removedOwnerKey)
        }

        for sourceEntry in sourceEntries {
            upsertTileRecord(sourceEntry)
        }

        ownerOrder = nextOwnerKeys
        labelInputsCount = ownerOrder.reduce(0) { partialResult, ownerKey in
            partialResult + (tileRecordsByOwnerKey[ownerKey]?.labelsCount ?? 0)
        }
        activeLabelSpanCount = arena.activeRangeSpanCount
        resizeTilePointInputs(to: activeLabelSpanCount)
        resizeLabelCollisionAABBInputs(to: activeLabelSpanCount)
        resizeLabelPresentationInputs(to: activeLabelSpanCount)
    }

    private func rebuildDrawBatches(_ sourceEntries: [BaseLabelSourceEntry]) {
        baseLabelsDrawBatches.removeAll(keepingCapacity: true)
        baseLabelsDrawBatches.reserveCapacity(sourceEntries.count)

        for sourceEntry in sourceEntries {
            guard let record = tileRecordsByOwnerKey[sourceEntry.ownerKey] else {
                continue
            }
            baseLabelsDrawBatches.append(BaseLabelDrawBatch(labelsByStyleRuns: record.labelsByStyleRuns,
                                                            poiIconRuns: record.poiIconRuns,
                                                            globalLabelStart: record.allocation.start,
                                                            labelInstanceCount: record.labelsCount))
        }
    }

    private func rebuildRuntimeMetaAndCollisionInputs(_ sourceEntries: [BaseLabelSourceEntry]) {
        guard activeLabelSpanCount > 0 else {
            labelRuntimeMetaData.removeAll(keepingCapacity: true)
            labelCollisionAABBInputs.removeAll(keepingCapacity: true)
            labelPresentationInputs.removeAll(keepingCapacity: true)
            return
        }

        resizeLabelRuntimeMetaData(to: activeLabelSpanCount)
        resizeLabelPresentationInputs(to: activeLabelSpanCount)
        for index in labelRuntimeMetaData.indices {
            labelRuntimeMetaData[index] = LabelRuntimeMeta(duplicate: 0,
                                                           isRetained: 0,
                                                           visibleTileIndex: 0,
                                                           fadeAlpha: 0,
                                                           labelSizePx: .zero)
        }
        for index in labelCollisionAABBInputs.indices {
            labelCollisionAABBInputs[index] = ScreenCollisionCandidate(position: .zero,
                                                                       halfSize: .zero,
                                                                       priority: .max,
                                                                       secondaryPriority: .max,
                                                                       isEnabled: false)
        }
        for index in labelPresentationInputs.indices {
            labelPresentationInputs[index] = .empty
        }

        var seenLabelKeys: Set<UInt64> = []
        seenLabelKeys.reserveCapacity(labelInputsCount)
        for sourceEntry in sourceEntries {
            guard let record = tileRecordsByOwnerKey[sourceEntry.ownerKey] else {
                continue
            }

            let rangeStart = record.allocation.start
            let validCount = record.labelsCount
            let rangeCapacity = record.allocation.capacity
            var runtimeMeta = Array(repeating: LabelRuntimeMeta(duplicate: 0,
                                                                isRetained: 0,
                                                                visibleTileIndex: 0,
                                                                fadeAlpha: 0,
                                                                labelSizePx: .zero),
                                    count: rangeCapacity)
            var aabbs = Array(repeating: ScreenCollisionCandidate(position: .zero,
                                                                  halfSize: .zero,
                                                                  priority: .max,
                                                                  secondaryPriority: .max,
                                                                  isEnabled: false),
                              count: rangeCapacity)
            var presentationInputs = Array(repeating: BaseLabelPresentationInput.empty,
                                           count: rangeCapacity)
            let sourcePriorityRank = BaseLabelSourceEntry.priorityRank(for: sourceEntry)

            for index in 0..<validCount {
                let labelKey = record.labelKeys[index]
                let duplicateFlag: UInt8 = seenLabelKeys.contains(labelKey) ? 1 : 0
                let labelSize = record.labelSizes[index]
                let labelCollisionPriority = record.labelCollisionPriorities[index]
                let labelSortKey = record.labelSortKeys[index]
                runtimeMeta[index] = LabelRuntimeMeta(duplicate: duplicateFlag,
                                                      isRetained: sourceEntry.isRetained ? 1 : 0,
                                                      visibleTileIndex: 0,
                                                      fadeAlpha: 0,
                                                      labelSizePx: labelSize)
                aabbs[index] = ScreenCollisionCandidate(position: .zero,
                                                        halfSize: SIMD2<Float>(labelSize.x * 0.5,
                                                                               labelSize.y * 0.5),
                                                        priority: labelCollisionPriority,
                                                        secondaryPriority: sourcePriorityRank,
                                                        sortPriority: labelSortKey,
                                                        stableOrderKey: labelKey,
                                                        groupId: labelKey,
                                                        isEnabled: duplicateFlag == 0)
                presentationInputs[index] = BaseLabelPresentationInput(labelKey: labelKey,
                                                                       duplicate: duplicateFlag,
                                                                       isRetained: sourceEntry.isRetained ? 1 : 0,
                                                                       isValid: true,
                                                                       minCameraZoom: record.labelMinCameraZooms[index])
                seenLabelKeys.insert(labelKey)
            }

            writeRuntimeMeta(runtimeMeta, start: rangeStart)
            writeCollisionAABBs(aabbs, start: rangeStart)
            writePresentationInputs(presentationInputs, start: rangeStart)
        }
    }

    private func rebuildTileSlotVisibleTileIndices(_ sourceEntries: [BaseLabelSourceEntry],
                                                   tileIndexAllocator: VisibleTileIndexAllocator) {
        let slotSpanCount = arena.activeTileSlotSpanCount
        if tileSlotVisibleTileIndices.count < slotSpanCount {
            tileSlotVisibleTileIndices.append(contentsOf: repeatElement(0, count: slotSpanCount - tileSlotVisibleTileIndices.count))
        } else if tileSlotVisibleTileIndices.count > slotSpanCount {
            tileSlotVisibleTileIndices.removeLast(tileSlotVisibleTileIndices.count - slotSpanCount)
        }

        if slotSpanCount > 0 {
            for index in 0..<slotSpanCount {
                tileSlotVisibleTileIndices[index] = 0
            }
        }

        for sourceEntry in sourceEntries {
            guard let record = tileRecordsByOwnerKey[sourceEntry.ownerKey] else {
                continue
            }
            let visibleTileIndex = tileIndexAllocator.tileIndex(for: sourceEntry.ownerKey)
            tileSlotVisibleTileIndices[Int(record.tileSlotIndex)] = visibleTileIndex
        }
    }

    private func upsertTileRecord(_ sourceEntry: BaseLabelSourceEntry) {
        let ownerKey = sourceEntry.ownerKey
        let metalTile = sourceEntry.metalTile
        let selectedTextLabelSet = metalTile.tileBuffers.textLabels.set(for: sourceEntry.labelDetailTier)
        let metalTileIdentity = sourceEntry.metalTileIdentity

        if var existingRecord = tileRecordsByOwnerKey[ownerKey] {
            let payloadChanged = existingRecord.metalTileIdentity != metalTileIdentity ||
                existingRecord.labelDetailTier != sourceEntry.labelDetailTier
            let requiresReallocation = selectedTextLabelSet.labelsCount > existingRecord.allocation.capacity
            if payloadChanged || requiresReallocation {
                if requiresReallocation {
                    releaseAllocation(existingRecord.allocation)
                    existingRecord.allocation = arena.allocateRange(requiredCount: selectedTextLabelSet.labelsCount)
                }

                let pointInputs = makeTilePointInputs(for: selectedTextLabelSet, tileSlotIndex: existingRecord.tileSlotIndex)
                resizeTilePointInputs(to: arena.activeRangeSpanCount)
                tilePointInputByOwnerKey[ownerKey] = pointInputs
                writePointInputs(pointInputs, at: existingRecord.allocation.start)
                existingRecord.metalTileIdentity = metalTileIdentity
                existingRecord.labelDetailTier = sourceEntry.labelDetailTier
                existingRecord.labelsCount = selectedTextLabelSet.labelsCount
                existingRecord.labelKeys = selectedTextLabelSet.placementInputs.map(\.placementMeta.key)
                existingRecord.labelSortKeys = selectedTextLabelSet.placementInputs.map(\.placementMeta.sortKey)
                existingRecord.labelCollisionPriorities = selectedTextLabelSet.placementInputs.map(\.placementMeta.collisionPriority)
                existingRecord.labelSizes = selectedTextLabelSet.placementInputs.map(\.placementMeta.labelSizePx)
                existingRecord.labelMinCameraZooms = selectedTextLabelSet.placementInputs.map(\.placementMeta.minCameraZoom)
                existingRecord.labelsByStyleRuns = selectedTextLabelSet.labelsByStyleRuns
                existingRecord.poiIconRuns = selectedTextLabelSet.poiIconRuns
            }

            existingRecord.isRetained = sourceEntry.isRetained
            tileRecordsByOwnerKey[ownerKey] = existingRecord
            return
        }

        let tileSlotIndex = arena.allocateTileSlot()
        let allocation = arena.allocateRange(requiredCount: selectedTextLabelSet.labelsCount)
        let pointInputs = makeTilePointInputs(for: selectedTextLabelSet, tileSlotIndex: tileSlotIndex)
        resizeTilePointInputs(to: arena.activeRangeSpanCount)
        tilePointInputByOwnerKey[ownerKey] = pointInputs
        writePointInputs(pointInputs, at: allocation.start)
        tileRecordsByOwnerKey[ownerKey] = TileRecord(ownerKey: ownerKey,
                                                           metalTileIdentity: metalTileIdentity,
                                                           labelDetailTier: sourceEntry.labelDetailTier,
                                                           isRetained: sourceEntry.isRetained,
                                                           tileSlotIndex: tileSlotIndex,
                                                           allocation: allocation,
                                                           labelsCount: selectedTextLabelSet.labelsCount,
                                                           labelKeys: selectedTextLabelSet.placementInputs.map(\.placementMeta.key),
                                                           labelSortKeys: selectedTextLabelSet.placementInputs.map(\.placementMeta.sortKey),
                                                           labelCollisionPriorities: selectedTextLabelSet.placementInputs.map(\.placementMeta.collisionPriority),
                                                           labelSizes: selectedTextLabelSet.placementInputs.map(\.placementMeta.labelSizePx),
                                                           labelMinCameraZooms: selectedTextLabelSet.placementInputs.map(\.placementMeta.minCameraZoom),
                                                           labelsByStyleRuns: selectedTextLabelSet.labelsByStyleRuns,
                                                           poiIconRuns: selectedTextLabelSet.poiIconRuns)
    }

    private func removeTileRecord(for ownerKey: VisibleTile) {
        guard let record = tileRecordsByOwnerKey.removeValue(forKey: ownerKey) else {
            return
        }

        tilePointInputByOwnerKey.removeValue(forKey: ownerKey)
        zeroPointInputRange(start: record.allocation.start, count: record.allocation.capacity)
        zeroCollisionAABBRange(start: record.allocation.start, count: record.allocation.capacity)
        releaseAllocation(record.allocation)
        arena.releaseTileSlot(record.tileSlotIndex)
    }

    private func releaseAllocation(_ allocation: BaseLabelTileArena.Allocation) {
        arena.releaseRange(allocation)
    }

    private func makeTilePointInputs(for selectedTextLabelSet: TileBuffers.TextLabelSet,
                                     tileSlotIndex: UInt32) -> [TilePointInput] {
        var pointInputs: [TilePointInput] = []
        pointInputs.reserveCapacity(selectedTextLabelSet.placementInputs.count)
        for label in selectedTextLabelSet.placementInputs {
            var pointInput = label.pointInput
            pointInput.tileSlotIndex = tileSlotIndex
            pointInputs.append(pointInput)
        }
        return pointInputs
    }

    private func resizeTilePointInputs(to count: Int) {
        if tilePointInputs.count < count {
            tilePointInputs.append(contentsOf: repeatElement(TilePointInput(uv: .zero,
                                                                            tile: .zero,
                                                                            tileSlotIndex: 0),
                                                            count: count - tilePointInputs.count))
        } else if tilePointInputs.count > count {
            tilePointInputs.removeLast(tilePointInputs.count - count)
        }
    }

    private func resizeLabelCollisionAABBInputs(to count: Int) {
        let zeroAABB = ScreenCollisionCandidate(position: .zero,
                                                halfSize: .zero,
                                                priority: .max,
                                                secondaryPriority: .max,
                                                isEnabled: false)
        if labelCollisionAABBInputs.count < count {
            labelCollisionAABBInputs.append(contentsOf: repeatElement(zeroAABB, count: count - labelCollisionAABBInputs.count))
        } else if labelCollisionAABBInputs.count > count {
            labelCollisionAABBInputs.removeLast(labelCollisionAABBInputs.count - count)
        }
    }

    private func resizeLabelRuntimeMetaData(to count: Int) {
        let zeroRuntimeMeta = LabelRuntimeMeta(duplicate: 0,
                                               isRetained: 0,
                                               visibleTileIndex: 0,
                                               fadeAlpha: 0,
                                               labelSizePx: .zero)
        if labelRuntimeMetaData.count < count {
            labelRuntimeMetaData.append(contentsOf: repeatElement(zeroRuntimeMeta, count: count - labelRuntimeMetaData.count))
        } else if labelRuntimeMetaData.count > count {
            labelRuntimeMetaData.removeLast(labelRuntimeMetaData.count - count)
        }
    }

    private func resizeLabelPresentationInputs(to count: Int) {
        if labelPresentationInputs.count < count {
            labelPresentationInputs.append(contentsOf: repeatElement(.empty, count: count - labelPresentationInputs.count))
        } else if labelPresentationInputs.count > count {
            labelPresentationInputs.removeLast(labelPresentationInputs.count - count)
        }
    }

    private func writePointInputs(_ pointInputs: [TilePointInput], at start: Int) {
        guard pointInputs.isEmpty == false else {
            return
        }

        for (offset, pointInput) in pointInputs.enumerated() {
            tilePointInputs[start + offset] = pointInput
        }
    }

    private func zeroPointInputRange(start: Int, count: Int) {
        guard count > 0, start < tilePointInputs.count else {
            return
        }

        let upperBound = min(tilePointInputs.count, start + count)
        for index in start..<upperBound {
            tilePointInputs[index] = TilePointInput(uv: .zero, tile: .zero, tileSlotIndex: 0)
        }
    }

    private func writeRuntimeMeta(_ runtimeMeta: [LabelRuntimeMeta], start: Int) {
        guard runtimeMeta.isEmpty == false else {
            return
        }

        for (offset, meta) in runtimeMeta.enumerated() {
            labelRuntimeMetaData[start + offset] = meta
        }
    }

    private func writeCollisionAABBs(_ aabbs: [ScreenCollisionCandidate], start: Int) {
        guard aabbs.isEmpty == false else {
            return
        }

        for (offset, aabb) in aabbs.enumerated() {
            labelCollisionAABBInputs[start + offset] = aabb
        }
    }

    private func writePresentationInputs(_ inputs: [BaseLabelPresentationInput], start: Int) {
        guard inputs.isEmpty == false else {
            return
        }

        for (offset, input) in inputs.enumerated() {
            labelPresentationInputs[start + offset] = input
        }
    }

    private func zeroCollisionAABBRange(start: Int, count: Int) {
        guard count > 0, start < labelCollisionAABBInputs.count else {
            return
        }

        let zeroAABB = ScreenCollisionCandidate(position: .zero,
                                                halfSize: .zero,
                                                priority: .max,
                                                secondaryPriority: .max,
                                                isEnabled: false)
        let upperBound = min(labelCollisionAABBInputs.count, start + count)
        for index in start..<upperBound {
            labelCollisionAABBInputs[index] = zeroAABB
        }
    }

    private func uploadRuntimeMeta(into buffer: MTLBuffer) {
        if labelRuntimeMetaData.isEmpty {
            writeDefaultRuntimeMeta(into: buffer)
            return
        }

        labelRuntimeMetaData.withUnsafeBytes { bytes in
            buffer.contents().copyMemory(from: bytes.baseAddress!,
                                         byteCount: labelRuntimeMetaData.count * MemoryLayout<LabelRuntimeMeta>.stride)
        }
    }

    private func writeDefaultRuntimeMeta(into buffer: MTLBuffer) {
        var runtimeMeta = LabelRuntimeMeta(duplicate: 0,
                                           isRetained: 0,
                                           visibleTileIndex: 0,
                                           fadeAlpha: 0)
        withUnsafeBytes(of: &runtimeMeta) { bytes in
            buffer.contents().copyMemory(from: bytes.baseAddress!,
                                         byteCount: MemoryLayout<LabelRuntimeMeta>.stride)
        }
    }
}
