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
/// The same feature reaches the set from several tiles (an exact tile and
/// the coarser one standing in beside it, placed whole), each copy under
/// the feature's key. The set keeps one: the copy of the tile earliest in
/// winner order, per world wrap, and marks the others as its copies
/// (`labelCopyOf`), which take no part in the frame. The copies need not
/// draw at one point (a roof in one tile, the ground in a coarser one that
/// draws no buildings), so they are told apart by key, never on screen.
///
/// Everything here is rebuilt when the tile set changes and read
/// otherwise: the per-label static arrays (anchor, collision box and rank,
/// presentation, copies), the set's rank order, the per-frame runtime meta
/// the shaders read, and the draw batches. The rank order is the tiles'
/// own orders (`TileBuffers.TextLabelSet.rankOrder`) merged, never a sort
/// of the whole set. Repacking the set is a loop over the tiles writing runs;
/// the change it hands back (`LabelWorkingSetChange`) says which runs
/// survived and where they went, so the frame's per-label state is
/// carried by copying runs, never by looking a label up.
final class BaseLabelCache {
    private struct TileRecord {
        let ownerKey: VisibleTile
        let metalTileIdentity: ObjectIdentifier
        let labelSet: TileBuffers.TextLabelSet
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
    /// Each label's collision box half size in layout points.
    private(set) var labelHalfSizes: [SIMD2<Float>] = []
    /// Each label's collision rank.
    private(set) var labelRanks: [BaseLabelRank] = []
    /// The set's labels in rank order, the order the collision solve
    /// places them in. Ties keep the earlier tile first.
    private(set) var rankOrder: [Int32] = []
    /// Each label's key, the identity a feature keeps across tiles: what a
    /// topology change matches a departing tile's lit labels to an arriving
    /// tile's by (`LabelWorkingSetChange.seeded`).
    private(set) var labelKeys: [UInt64] = []
    /// For each label the index of the copy of its feature the set keeps,
    /// -1 for a label the set keeps itself.
    private(set) var labelCopyOf: [Int32] = []
    /// The labels that are copies, in index order: what a topology change
    /// hands the kept copies' fades over from.
    private(set) var copyIndices: [Int] = []

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
        labelHalfSizes.removeAll(keepingCapacity: false)
        labelRanks.removeAll(keepingCapacity: false)
        rankOrder.removeAll(keepingCapacity: false)
        labelKeys.removeAll(keepingCapacity: false)
        labelCopyOf.removeAll(keepingCapacity: false)
        copyIndices.removeAll(keepingCapacity: false)
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

    /// Each tile's labels in the set, in the set's order: a tile's labels
    /// are ordered by the zoom they show from (`TileTextLabelsBuilder`),
    /// which is what `LabelActiveSpans` searches.
    var tileRuns: [Range<Int>] {
        records.map { $0.start..<($0.start + $0.count) }
    }

    /// Each label's shrink for its distance, index-aligned with the set.
    /// Only the labels of `spans` are written (`LabelActiveSpans`). Nil
    /// writes every label.
    func updatePerspectiveScales(_ scales: [Float], spans: [Range<Int>]? = nil) {
        let count = min(labelRuntimeMetaData.count, scales.count)
        labelRuntimeMetaData.withUnsafeMutableBufferPointer { meta in
            scales.withUnsafeBufferPointer { scales in
                for span in spans ?? [0..<meta.count] {
                    var index = span.lowerBound
                    let end = min(span.upperBound, meta.count)
                    while index < end {
                        meta[index].perspectiveScale = index < count ? scales[index] : 1
                        index += 1
                    }
                }
            }
        }
    }

    /// Each label's fade alpha times `multiplier`, index-aligned with the
    /// set, into the runtime meta the shaders read. Only the labels of
    /// `spans` are written (`LabelActiveSpans`): the rest are dark and keep
    /// the 0 they left with. Nil writes every label.
    func updateFadeAlphas(_ fadeAlphas: [Float], multiplier: Float = 1.0, spans: [Range<Int>]? = nil) {
        let count = min(labelRuntimeMetaData.count, fadeAlphas.count)
        labelRuntimeMetaData.withUnsafeMutableBufferPointer { meta in
            fadeAlphas.withUnsafeBufferPointer { alphas in
                for span in spans ?? [0..<meta.count] {
                    var index = span.lowerBound
                    let end = min(span.upperBound, meta.count)
                    while index < end {
                        meta[index].fadeAlpha = index < count ? alphas[index] * multiplier : 0
                        index += 1
                    }
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
        mergeRankOrder()
        markCopies()
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
        labelHalfSizes = Array(repeating: .zero, count: total)
        labelRanks = Array(repeating: BaseLabelRank(priority: 0, sortPriority: 0, key: 0), count: total)
        labelKeys = Array(repeating: 0, count: total)
        labelPresentationInputs = Array(repeating: BaseLabelPresentationInput(labelKey: 0, minCameraZoom: 0), count: total)
        labelRuntimeMetaData = Array(repeating: LabelRuntimeMeta(), count: total)
        guard total > 0 else {
            return
        }

        tilePointInputs.withUnsafeMutableBufferPointer { points in
        labelHalfSizes.withUnsafeMutableBufferPointer { halfSizes in
        labelRanks.withUnsafeMutableBufferPointer { ranks in
        labelKeys.withUnsafeMutableBufferPointer { keys in
        labelPresentationInputs.withUnsafeMutableBufferPointer { presentation in
        labelRuntimeMetaData.withUnsafeMutableBufferPointer { meta in
            for (tileOrder, record) in records.enumerated() where record.count > 0 {
                let tileSlotIndex = UInt32(tileOrder)
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
                        halfSizes[index] = placementMeta.labelSizePoints * 0.5
                        ranks[index] = BaseLabelRank(placementMeta: placementMeta)
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

    /// The tiles' rank orders laid end to end in the set's indices, then
    /// merged into one.
    private func mergeRankOrder() {
        rankOrder = Array(repeating: 0, count: labelInputsCount)
        rankOrder.withUnsafeMutableBufferPointer { order in
            for record in records where record.count > 0 {
                record.labelSet.rankOrder.withUnsafeBufferPointer { tileOrder in
                    let count = min(record.count, tileOrder.count)
                    let start = Int32(record.start)
                    var offset = 0
                    while offset < count {
                        order[record.start + offset] = start + tileOrder[offset]
                        offset += 1
                    }
                }
            }
        }
        BaseLabelRankOrder.mergeRuns(&rankOrder, runs: tileRuns, ranks: labelRanks)
    }

    /// Keeps the first copy of each feature in the set's order, the tiles
    /// being in winner order, per world wrap, and points the later copies
    /// at it. A label without a key is nobody's copy.
    private func markCopies() {
        struct Feature: Hashable {
            let key: UInt64
            let worldWrap: Int8
        }
        labelCopyOf = Array(repeating: -1, count: labelInputsCount)
        copyIndices.removeAll(keepingCapacity: true)
        guard labelInputsCount > 0 else {
            return
        }
        var kept: [Feature: Int32] = [:]
        kept.reserveCapacity(labelInputsCount)
        labelKeys.withUnsafeBufferPointer { keys in
        labelPresentationInputs.withUnsafeMutableBufferPointer { presentation in
        labelCopyOf.withUnsafeMutableBufferPointer { copyOf in
            for record in records where record.count > 0 {
                let worldWrap = record.ownerKey.worldWrap
                var index = record.start
                let end = record.start + record.count
                while index < end {
                    let key = keys[index]
                    if key != 0 {
                        let feature = Feature(key: key, worldWrap: worldWrap)
                        if let keptIndex = kept[feature] {
                            copyOf[index] = keptIndex
                            presentation[index].isCopy = true
                            copyIndices.append(index)
                        } else {
                            kept[feature] = Int32(index)
                        }
                    }
                    index += 1
                }
            }
        }}}
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
