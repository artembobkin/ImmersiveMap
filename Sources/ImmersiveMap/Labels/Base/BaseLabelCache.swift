// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  BaseLabelCache.swift
//  ImmersiveMap
//

import Metal
import simd

/// The `Labels` folder: runtime label state after the schema-specific
/// decisions have been made in `VectorTileAdaptation`: the base and road label
/// caches, collision inputs, draw batches, placement metadata and the visible
/// tile indices, plus the POI sprite resolution over already normalized data.
/// It never knows the raw tile schema, the language fallback or the label
/// identity rules, and holds no Metal, no tile loading or parsing, and no
/// views.
///
/// The base labels of the frame's tiles as one packed working set: the
/// tiles in winner order (`BaseLabelSourceEntry`), each tile's labels one
/// run in tile-local order, the runs laid end to end. A label's global
/// index is its tile's start plus its index in the tile, the number the
/// tile's vertices carry and the shaders add the tile's start to.
///
/// Everything here is rebuilt when the tile set changes and read
/// otherwise: the per-label static arrays (anchor, collision box and rank,
/// presentation), the per-frame runtime meta the shaders read, and the
/// draw batches. Repacking the set is a loop over the tiles writing runs;
/// the change it hands back (`LabelWorkingSetChange`) says which runs
/// survived and where they went, so the frame's per-label state is
/// carried by copying runs, never by looking a label up.
final class BaseLabelCache {
    private struct TileRecord {
        let ownerKey: VisibleTile
        let metalTileIdentity: ObjectIdentifier
        let labelSet: TileBuffers.TextLabelSet
        let sourcePriorityRank: Int
        let start: Int
        let count: Int
    }

    private let labelRuntimeMetaBufferStore: FrameSlottedDynamicMetalBuffer<LabelRuntimeMeta>

    private var records: [TileRecord] = []
    private var tileSlotVisibleTileIndices: [UInt32] = []
    private var labelRuntimeMetaData: [LabelRuntimeMeta] = []
    private var labelPresentationInputs: [BaseLabelPresentationInput] = []

    private(set) var baseLabelsDrawBatches: [BaseLabelDrawBatch] = []

    /// The number of labels in the set, the length of every per-label array.
    private(set) var labelInputsCount: Int = 0
    private(set) var tilePointInputs: [TilePointInput] = []
    private(set) var labelCollisionAABBInputs: [ScreenCollisionCandidate] = []
    /// Each label's tile's position in the set: the tile order the
    /// collision rank breaks ties by, so the set's preferred copy of a
    /// feature is placed before the others.
    private(set) var labelTileOrders: [Int] = []
    /// Each label's key, the identity a feature keeps across tiles: what a
    /// topology change matches a departing tile's lit labels to an arriving
    /// tile's by (`LabelWorkingSetChange.seeded`).
    private(set) var labelKeys: [UInt64] = []

    init(metalDevice: MTLDevice) {
        self.labelRuntimeMetaBufferStore = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                                          slotsCount: InFlightFramePool.inFlightFramesCount,
                                                                          options: [.storageModeShared])
    }

    @discardableResult
    func rebuild(sourceEntries: [BaseLabelSourceEntry],
                 tileIndexAllocator: VisibleTileIndexAllocator) -> LabelWorkingSetChange {
        synchronize(sourceEntries: sourceEntries,
                    tileIndexAllocator: tileIndexAllocator,
                    trackedTilesChanged: true,
                    projectionChanged: true) ?? .empty
    }

    /// Brings the set up to `sourceEntries`. With `trackedTilesChanged` the
    /// set is repacked and the change returned; otherwise nil, and with
    /// `projectionChanged` only the tiles' projection indices are refreshed.
    @discardableResult
    func synchronize(sourceEntries: [BaseLabelSourceEntry],
                     tileIndexAllocator: VisibleTileIndexAllocator,
                     trackedTilesChanged: Bool,
                     projectionChanged: Bool) -> LabelWorkingSetChange? {
        var change: LabelWorkingSetChange?
        if trackedTilesChanged {
            change = repack(sourceEntries)
        }
        if trackedTilesChanged || projectionChanged {
            rebuildTileSlotVisibleTileIndices(tileIndexAllocator: tileIndexAllocator)
        }
        return change
    }

    func reset() {
        records.removeAll(keepingCapacity: false)
        tileSlotVisibleTileIndices.removeAll(keepingCapacity: false)
        baseLabelsDrawBatches.removeAll(keepingCapacity: false)
        tilePointInputs.removeAll(keepingCapacity: false)
        labelCollisionAABBInputs.removeAll(keepingCapacity: false)
        labelTileOrders.removeAll(keepingCapacity: false)
        labelKeys.removeAll(keepingCapacity: false)
        labelRuntimeMetaData.removeAll(keepingCapacity: false)
        labelPresentationInputs.removeAll(keepingCapacity: false)
        labelInputsCount = 0
    }

    var tilePointSnapshot: TilePointToScreenPointSnapshot {
        TilePointToScreenPointSnapshot(pointInputs: tilePointInputs,
                                       tileSlotVisibleTileIndices: tileSlotVisibleTileIndices)
    }

    /// The runtime meta of the set for the frame's slot, uploaded whole.
    func labelRuntimeMetaBuffer(frameSlotIndex: Int) -> MTLBuffer {
        let buffer = labelRuntimeMetaBufferStore.ensureCapacity(slot: frameSlotIndex,
                                                                count: max(1, labelInputsCount))
        if labelRuntimeMetaData.isEmpty {
            var runtimeMeta = LabelRuntimeMeta()
            withUnsafeBytes(of: &runtimeMeta) { bytes in
                buffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: MemoryLayout<LabelRuntimeMeta>.stride)
            }
        } else {
            labelRuntimeMetaData.withUnsafeBytes { bytes in
                buffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            }
        }
        return buffer
    }

    var presentationInputs: [BaseLabelPresentationInput] {
        labelPresentationInputs
    }

    /// Each label's shrink for its distance, index-aligned with the set.
    func updatePerspectiveScales(_ scales: [Float]) {
        let count = min(labelRuntimeMetaData.count, scales.count)
        labelRuntimeMetaData.withUnsafeMutableBufferPointer { meta in
            scales.withUnsafeBufferPointer { scales in
                var index = 0
                while index < count {
                    meta[index].perspectiveScale = scales[index]
                    index += 1
                }
                while index < meta.count {
                    meta[index].perspectiveScale = 1
                    index += 1
                }
            }
        }
    }

    /// Each label's fade alpha times `multiplier`, index-aligned with the
    /// set, into the runtime meta the shaders read.
    func updateFadeAlphas(_ fadeAlphas: [Float], multiplier: Float = 1.0) {
        let count = min(labelRuntimeMetaData.count, fadeAlphas.count)
        labelRuntimeMetaData.withUnsafeMutableBufferPointer { meta in
            fadeAlphas.withUnsafeBufferPointer { alphas in
                var index = 0
                while index < count {
                    meta[index].fadeAlpha = alphas[index] * multiplier
                    index += 1
                }
                while index < meta.count {
                    meta[index].fadeAlpha = 0
                    index += 1
                }
            }
        }
    }

    // MARK: - Packing

    /// Lays the tiles of `sourceEntries` out end to end and rewrites every
    /// per-label array from the tiles' label sets. A tile that stays with
    /// the same payload is a run that survived: its old and new place go
    /// into the change. A tile whose payload was replaced counts as new,
    /// so its labels fade in like a fresh tile's.
    private func repack(_ sourceEntries: [BaseLabelSourceEntry]) -> LabelWorkingSetChange {
        let previousRecords = records
        var previousIndexByOwnerKey: [VisibleTile: Int] = [:]
        previousIndexByOwnerKey.reserveCapacity(previousRecords.count)
        for (index, record) in previousRecords.enumerated() {
            previousIndexByOwnerKey[record.ownerKey] = index
        }

        var nextRecords: [TileRecord] = []
        nextRecords.reserveCapacity(sourceEntries.count)
        var moves: [LabelBlockMove] = []
        var arrivedRuns: [Range<Int>] = []
        var survived = [Bool](repeating: false, count: previousRecords.count)
        var start = 0
        for entry in sourceEntries {
            let labelSet = entry.metalTile.tileBuffers.textLabels
            let count = labelSet.labelsCount
            let identity = entry.metalTileIdentity
            if let previousIndex = previousIndexByOwnerKey[entry.ownerKey],
               previousRecords[previousIndex].metalTileIdentity == identity {
                survived[previousIndex] = true
                if count > 0 {
                    moves.append(LabelBlockMove(oldStart: previousRecords[previousIndex].start,
                                                newStart: start,
                                                count: count))
                }
            } else if count > 0 {
                arrivedRuns.append(start..<(start + count))
            }
            nextRecords.append(TileRecord(ownerKey: entry.ownerKey,
                                          metalTileIdentity: identity,
                                          labelSet: labelSet,
                                          sourcePriorityRank: BaseLabelSourceEntry.priorityRank(for: entry),
                                          start: start,
                                          count: count))
            start += count
        }
        var departedRuns: [Range<Int>] = []
        for (index, record) in previousRecords.enumerated() where survived[index] == false && record.count > 0 {
            departedRuns.append(record.start..<(record.start + record.count))
        }
        let previousKeys = labelKeys
        records = nextRecords
        labelInputsCount = start

        rewriteLabelArrays()
        rebuildDrawBatches()
        return LabelWorkingSetChange(count: start,
                                     moves: moves,
                                     departedRuns: departedRuns,
                                     arrivedRuns: arrivedRuns,
                                     previousKeys: previousKeys,
                                     keys: labelKeys)
    }

    private func rewriteLabelArrays() {
        let total = labelInputsCount
        tilePointInputs = Array(repeating: TilePointInput(uv: .zero, tile: .zero, tileSlotIndex: 0), count: total)
        labelCollisionAABBInputs = Array(repeating: ScreenCollisionCandidate(position: .zero, halfSize: .zero, isEnabled: false),
                                         count: total)
        labelTileOrders = Array(repeating: 0, count: total)
        labelKeys = Array(repeating: 0, count: total)
        labelPresentationInputs = Array(repeating: BaseLabelPresentationInput(labelKey: 0, minCameraZoom: 0), count: total)
        labelRuntimeMetaData = Array(repeating: LabelRuntimeMeta(), count: total)
        guard total > 0 else {
            return
        }

        tilePointInputs.withUnsafeMutableBufferPointer { points in
        labelCollisionAABBInputs.withUnsafeMutableBufferPointer { candidates in
        labelTileOrders.withUnsafeMutableBufferPointer { tileOrders in
        labelKeys.withUnsafeMutableBufferPointer { keys in
        labelPresentationInputs.withUnsafeMutableBufferPointer { presentation in
        labelRuntimeMetaData.withUnsafeMutableBufferPointer { meta in
            for (tileOrder, record) in records.enumerated() where record.count > 0 {
                let tileSlotIndex = UInt32(tileOrder)
                let sourcePriorityRank = record.sourcePriorityRank
                record.labelSet.placementInputs.withUnsafeBufferPointer { inputs in
                    let count = min(record.count, inputs.count)
                    var offset = 0
                    while offset < count {
                        let input = inputs[offset]
                        let placementMeta = input.placementMeta
                        let index = record.start + offset
                        var point = input.pointInput
                        point.tileSlotIndex = tileSlotIndex
                        points[index] = point
                        candidates[index] = ScreenCollisionCandidate(position: .zero,
                                                                     halfSize: placementMeta.labelSizePoints * 0.5,
                                                                     priority: placementMeta.collisionPriority,
                                                                     secondaryPriority: sourcePriorityRank,
                                                                     sortPriority: placementMeta.sortKey,
                                                                     stableOrderKey: placementMeta.key,
                                                                     groupId: placementMeta.key,
                                                                     isEnabled: true)
                        tileOrders[index] = tileOrder
                        keys[index] = placementMeta.key
                        presentation[index] = BaseLabelPresentationInput(labelKey: placementMeta.key,
                                                                         minCameraZoom: placementMeta.minCameraZoom,
                                                                         isLocal: placementMeta.isLocal)
                        meta[index] = LabelRuntimeMeta(fadeAlpha: 0,
                                                       perspectiveScale: 1,
                                                       labelSizePoints: placementMeta.labelSizePoints)
                        offset += 1
                    }
                }
            }
        }}}}}}
    }

    private func rebuildDrawBatches() {
        baseLabelsDrawBatches.removeAll(keepingCapacity: true)
        baseLabelsDrawBatches.reserveCapacity(records.count)
        for record in records where record.count > 0 {
            baseLabelsDrawBatches.append(BaseLabelDrawBatch(labelsByStyleRuns: record.labelSet.labelsByStyleRuns,
                                                            poiIconRuns: record.labelSet.poiIconRuns,
                                                            routeShieldRuns: record.labelSet.routeShieldRuns,
                                                            globalLabelStart: record.start,
                                                            labelInstanceCount: record.count))
        }
    }

    /// Each tile's index in the frame's tile origin table, by the tile's
    /// position in the set, which is the `tileSlotIndex` its labels carry.
    private func rebuildTileSlotVisibleTileIndices(tileIndexAllocator: VisibleTileIndexAllocator) {
        if tileSlotVisibleTileIndices.count != records.count {
            tileSlotVisibleTileIndices = Array(repeating: 0, count: records.count)
        }
        for (index, record) in records.enumerated() {
            tileSlotVisibleTileIndices[index] = tileIndexAllocator.tileIndex(for: record.ownerKey)
        }
    }
}
