// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  RoadLabelCache.swift
//  ImmersiveMap
//

import Foundation
import Metal
import simd

/// One tile's road labels in the working set: the roads and glyphs the
/// placer reads, the glyph data the shader reads, and the frame's placement
/// of the glyphs, kept here so a tile culled from the near set keeps
/// drawing its last placement while its labels fade out.
final class RoadLabelTileRecord {
    let ownerKey: VisibleTile
    let metalTileIdentity: ObjectIdentifier
    private(set) var sourcePriority: Int
    var visibleTileIndex: UInt32
    /// Where the record's instances start in the cache's instance set.
    var instanceStart: Int = 0

    let labelStyle: LabelTextStyle
    let geometry: RoadLabelPlacer.Geometry
    let instanceKeys: [UInt64]
    let instanceLabelSizes: [SIMD2<Float>]
    let instanceAnchorOrdinals: [UInt32]
    private(set) var instanceSourcePriorities: [Int]
    /// The number of roads the record labels, for the diagnostics.
    let pathCount: Int

    let localGlyphVertices: TileBufferView?
    /// The glyph data the road text vertex shader reads, uploaded once.
    let glyphInputsBuffer: MTLBuffer?

    /// The last placement of the record's glyphs (`RoadLabelPlacer`),
    /// hidden until the record is first placed.
    var placement = RoadLabelPlacer.Output()

    private let placementBufferStore: FrameSlottedDynamicMetalBuffer<RoadGlyphPlacementOutput>
    private let runtimeMetaBufferStore: FrameSlottedDynamicMetalBuffer<LabelRuntimeMeta>

    var glyphCount: Int {
        geometry.glyphCount
    }

    var instanceCount: Int {
        instanceKeys.count
    }

    var instanceGlyphRanges: [Range<Int>] {
        geometry.instanceGlyphRanges
    }

    init(metalDevice: MTLDevice,
         ownerKey: VisibleTile,
         metalTileIdentity: ObjectIdentifier,
         sourcePriority: Int,
         visibleTileIndex: UInt32,
         labelStyle: LabelTextStyle,
         geometry: RoadLabelPlacer.Geometry,
         pathCount: Int,
         instanceKeys: [UInt64],
         instanceLabelSizes: [SIMD2<Float>],
         instanceAnchorOrdinals: [UInt32],
         localGlyphVertices: TileBufferView?) {
        self.ownerKey = ownerKey
        self.metalTileIdentity = metalTileIdentity
        self.sourcePriority = sourcePriority
        self.visibleTileIndex = visibleTileIndex
        self.labelStyle = labelStyle
        self.geometry = geometry
        self.pathCount = pathCount
        self.instanceKeys = instanceKeys
        self.instanceLabelSizes = instanceLabelSizes
        self.instanceAnchorOrdinals = instanceAnchorOrdinals
        self.instanceSourcePriorities = Array(repeating: sourcePriority, count: instanceKeys.count)
        self.localGlyphVertices = localGlyphVertices
        self.glyphInputsBuffer = Self.makeBuffer(device: metalDevice, values: geometry.glyphs)
        self.placementBufferStore = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                                   slotsCount: InFlightFramePool.inFlightFramesCount,
                                                                   options: [.storageModeShared])
        self.runtimeMetaBufferStore = FrameSlottedDynamicMetalBuffer(metalDevice: metalDevice,
                                                                     slotsCount: InFlightFramePool.inFlightFramesCount,
                                                                     options: [.storageModeShared])
        placement.resize(glyphCount: geometry.glyphCount)
    }

    var hasRenderableGlyphs: Bool {
        glyphCount > 0 && (localGlyphVertices?.count ?? 0) > 0 && glyphInputsBuffer != nil
    }

    func updateMetadata(sourcePriority: Int) {
        self.sourcePriority = sourcePriority
        if instanceSourcePriorities.isEmpty == false {
            instanceSourcePriorities = Array(repeating: sourcePriority, count: instanceSourcePriorities.count)
        }
    }

    /// The frame slot's copy of the record's placement, for the shader.
    func placementBuffer(slot: Int) -> MTLBuffer {
        let buffer = placementBufferStore.ensureCapacity(slot: slot, count: max(1, glyphCount))
        placement.placements.withUnsafeBytes { bytes in
            if bytes.count > 0 {
                buffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            }
        }
        return buffer
    }

    /// The frame slot's copy of the record's instance meta (the fades).
    func runtimeMetaBuffer(slot: Int, meta: [LabelRuntimeMeta]) -> MTLBuffer {
        let buffer = runtimeMetaBufferStore.ensureCapacity(slot: slot, count: max(1, meta.count))
        meta.withUnsafeBytes { bytes in
            if bytes.count > 0 {
                buffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            }
        }
        return buffer
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

/// The road labels of the frame's tiles: one record per tile in the base
/// labels' winner order, the records' instances packed end to end into one
/// instance set the fades and the collision decisions are index-aligned
/// with. A tile that stays keeps its record; a topology change repacks the
/// instance set and reports the runs that survived.
final class RoadLabelCache {
    private let metalDevice: MTLDevice

    private var tileRecordsByOwnerKey: [VisibleTile: RoadLabelTileRecord] = [:]

    private(set) var instanceKeys: [UInt64] = []
    private(set) var instanceLabelSizes: [SIMD2<Float>] = []

    /// The records in the set's order. Materialized: membership changes only
    /// in synchronize and evict, and the frame reads this in several places.
    private(set) var orderedTileRecords: [RoadLabelTileRecord] = []

    init(metalDevice: MTLDevice) {
        self.metalDevice = metalDevice
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
    /// instance set is repacked and the change returned; otherwise nil,
    /// and with `projectionChanged` only the tiles' projection indices are
    /// refreshed.
    @discardableResult
    func synchronize(sourceEntries: [BaseLabelSourceEntry],
                     tileIndexAllocator: VisibleTileIndexAllocator,
                     trackedTilesChanged: Bool,
                     projectionChanged: Bool) -> LabelWorkingSetChange? {
        var change: LabelWorkingSetChange?
        if trackedTilesChanged {
            change = synchronizeTrackedTiles(sourceEntries: sourceEntries,
                                             tileIndexAllocator: tileIndexAllocator)
        } else if projectionChanged {
            for sourceEntry in sourceEntries {
                tileRecordsByOwnerKey[sourceEntry.ownerKey]?.visibleTileIndex =
                    tileIndexAllocator.tileIndex(for: sourceEntry.ownerKey)
            }
        }
        return change
    }

    func evict() {
        tileRecordsByOwnerKey.removeAll(keepingCapacity: false)
        orderedTileRecords.removeAll(keepingCapacity: false)
        instanceKeys.removeAll(keepingCapacity: false)
        instanceLabelSizes.removeAll(keepingCapacity: false)
    }

    private func synchronizeTrackedTiles(sourceEntries: [BaseLabelSourceEntry],
                                         tileIndexAllocator: VisibleTileIndexAllocator) -> LabelWorkingSetChange {
        var previousStartByOwnerKey: [VisibleTile: (identity: ObjectIdentifier, start: Int)] = [:]
        previousStartByOwnerKey.reserveCapacity(orderedTileRecords.count)
        for record in orderedTileRecords {
            previousStartByOwnerKey[record.ownerKey] = (record.metalTileIdentity, record.instanceStart)
        }

        var nextRecordsByOwnerKey: [VisibleTile: RoadLabelTileRecord] = [:]
        nextRecordsByOwnerKey.reserveCapacity(sourceEntries.count)
        var nextOrdered: [RoadLabelTileRecord] = []
        nextOrdered.reserveCapacity(sourceEntries.count)
        var moves: [LabelBlockMove] = []
        instanceKeys.removeAll(keepingCapacity: true)
        instanceLabelSizes.removeAll(keepingCapacity: true)

        var start = 0
        for sourceEntry in sourceEntries {
            let ownerKey = sourceEntry.ownerKey
            let visibleTileIndex = tileIndexAllocator.tileIndex(for: ownerKey)
            let sourcePriority = BaseLabelSourceEntry.priorityRank(for: sourceEntry)
            let record: RoadLabelTileRecord
            if let existing = tileRecordsByOwnerKey[ownerKey],
               existing.metalTileIdentity == sourceEntry.metalTileIdentity {
                record = existing
                record.updateMetadata(sourcePriority: sourcePriority)
                if record.instanceCount > 0, let previous = previousStartByOwnerKey[ownerKey] {
                    moves.append(LabelBlockMove(oldStart: previous.start, newStart: start, count: record.instanceCount))
                }
            } else {
                record = makeTileRecord(sourceEntry: sourceEntry,
                                        sourcePriority: sourcePriority,
                                        visibleTileIndex: visibleTileIndex)
            }
            record.visibleTileIndex = visibleTileIndex
            record.instanceStart = start
            instanceKeys.append(contentsOf: record.instanceKeys)
            instanceLabelSizes.append(contentsOf: record.instanceLabelSizes)
            start += record.instanceCount
            nextRecordsByOwnerKey[ownerKey] = record
            nextOrdered.append(record)
        }

        // A road instance's key holds its tile, so an instance never
        // outlives its record: the surviving records' runs are all there
        // is to carry.
        tileRecordsByOwnerKey = nextRecordsByOwnerKey
        orderedTileRecords = nextOrdered
        return LabelWorkingSetChange(count: start, moves: moves)
    }

    private func makeTileRecord(sourceEntry: BaseLabelSourceEntry,
                                sourcePriority: Int,
                                visibleTileIndex: UInt32) -> RoadLabelTileRecord {
        let roadLabels = sourceEntry.metalTile.tileBuffers.roadLabels
        let style = roadLabels.labelStyle ?? Self.fallbackStyle

        var instanceKeys: [UInt64] = []
        var instanceLabelSizes: [SIMD2<Float>] = []
        var instanceAnchorOrdinals: [UInt32] = []
        var pathPoints: [TilePointInput] = []
        var pathRanges: [Range<Int>] = []
        var pathInstanceRanges: [Range<Int>] = []
        var anchors: [RoadLabelPlacer.Anchor] = []
        var instanceGlyphRanges: [Range<Int>] = []
        var glyphs: [RoadGlyphInput] = []
        var glyphHalfSizes: [SIMD2<Float>] = []

        // Every path's points first, then the anchors' own points, so a
        // path's points stay contiguous.
        var anchorPointInputs: [TilePointInput] = []
        struct PendingAnchor {
            let pathIndex: Int32
            let segmentIndex: Int32
            let anchorPointOffset: Int
        }
        var pendingAnchors: [PendingAnchor] = []

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
            guard Self.totalLength(points: localPathInputs.map(Self.makeCanonicalPoint)) > 0 else {
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
            let pathIndex = Int32(pathRanges.count)
            let entryKey = Self.makeEntryKey(ownerKey: sourceEntry.ownerKey,
                                             sourceKey: roadLabels.pathLabels[labelIndex].key,
                                             labelIndex: labelIndex,
                                             pathRange: pathRange)
            let labelSize = roadLabels.sizes[labelIndex]

            let pathStart = pathPoints.count
            pathPoints.append(contentsOf: localPathInputs)
            pathRanges.append(pathStart..<pathPoints.count)

            let labelMinY = glyphBounds.reduce(Float.greatestFiniteMagnitude) { min($0, $1.z) }
            let labelMaxY = glyphBounds.reduce(-Float.greatestFiniteMagnitude) { max($0, $1.w) }
            let labelCenterY = (labelMinY + labelMaxY) * 0.5

            let firstInstance = instanceKeys.count
            for anchor in roadLabels.anchors[anchorRange.start..<anchorEnd] {
                let instanceIndex = UInt32(instanceKeys.count)
                instanceKeys.append(Self.makeInstanceKey(entryKey: entryKey, anchorOrdinal: anchor.anchorOrdinal))
                instanceLabelSizes.append(labelSize)
                instanceAnchorOrdinals.append(anchor.anchorOrdinal)
                // The anchor rides the point stream as its own point, so the
                // placer reads the anchor's true projected position instead of
                // lerping along the projected segment, which drifts under
                // perspective.
                pendingAnchors.append(PendingAnchor(pathIndex: pathIndex,
                                                    segmentIndex: Int32(anchor.segmentIndex),
                                                    anchorPointOffset: anchorPointInputs.count))
                anchorPointInputs.append(Self.makeAnchorPointInput(anchor: anchor, path: localPathInputs))

                let instanceGlyphStart = glyphs.count
                for bounds in glyphBounds {
                    glyphs.append(RoadGlyphInput(pathIndex: UInt32(pathIndex),
                                                 instanceIndex: instanceIndex,
                                                 labelInstanceIndex: instanceIndex,
                                                 glyphCenter: (bounds.x + bounds.y) * 0.5,
                                                 labelCenterY: labelCenterY,
                                                 labelWidth: labelSize.x,
                                                 spacing: 0,
                                                 minLength: labelSize.x))
                    glyphHalfSizes.append(SIMD2<Float>((bounds.y - bounds.x) * 0.5, (bounds.w - bounds.z) * 0.5))
                }
                instanceGlyphRanges.append(instanceGlyphStart..<glyphs.count)
            }
            pathInstanceRanges.append(firstInstance..<instanceKeys.count)
        }

        let anchorPointsStart = pathPoints.count
        pathPoints.append(contentsOf: anchorPointInputs)
        for pending in pendingAnchors {
            anchors.append(RoadLabelPlacer.Anchor(pathIndex: pending.pathIndex,
                                                  segmentIndex: pending.segmentIndex,
                                                  pointIndex: Int32(anchorPointsStart + pending.anchorPointOffset)))
        }

        let geometry = RoadLabelPlacer.Geometry(pathPoints: pathPoints,
                                                pathRanges: pathRanges,
                                                pathInstanceRanges: pathInstanceRanges,
                                                anchors: anchors,
                                                instanceGlyphRanges: instanceGlyphRanges,
                                                glyphs: glyphs,
                                                glyphHalfSizes: glyphHalfSizes)
        return RoadLabelTileRecord(metalDevice: metalDevice,
                                   ownerKey: sourceEntry.ownerKey,
                                   metalTileIdentity: sourceEntry.metalTileIdentity,
                                   sourcePriority: sourcePriority,
                                   visibleTileIndex: visibleTileIndex,
                                   labelStyle: style,
                                   geometry: geometry,
                                   pathCount: pathRanges.count,
                                   instanceKeys: instanceKeys,
                                   instanceLabelSizes: instanceLabelSizes,
                                   instanceAnchorOrdinals: instanceAnchorOrdinals,
                                   localGlyphVertices: roadLabels.localGlyphVertices)
    }

    // The anchor's world position as a projectable point: interpolated in tile
    // UV space on its segment. Requires `path.count >= 2` (the caller's path
    // range guard).
    static func makeAnchorPointInput(anchor: RoadLabelAnchor,
                                     path: [TilePointInput]) -> TilePointInput {
        let segmentIndex = min(max(Int(anchor.segmentIndex), 0), path.count - 2)
        let t = min(max(anchor.t, 0.0), 1.0)
        let segmentStart = path[segmentIndex]
        let segmentEnd = path[segmentIndex + 1]
        return TilePointInput(uv: segmentStart.uv + (segmentEnd.uv - segmentStart.uv) * t,
                              tile: segmentStart.tile,
                              tileSlotIndex: segmentStart.tileSlotIndex)
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
        hasher.combine(ownerKey.worldWrap)
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

    static let fallbackStyle = LabelTextStyle(key: 0,
                                              fillColor: SIMD3<Float>(0.54, 0.54, 0.52),
                                              strokeColor: SIMD3<Float>(0.54, 0.54, 0.52),
                                              haloEm: 0.0,
                                              sizePoints: 18.0,
                                              weight: .thin)
}
