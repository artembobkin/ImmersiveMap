// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The rank a label competes with: lower wins. Two copies of one feature
/// (an exact tile's and a stand-in's) rank alike down to the tile order,
/// which is the working set's winner order, so the copy the set prefers is
/// placed first and the other is found to be its duplicate. Ties beyond
/// that fall to the stable key.
struct LabelCollisionRank: Equatable {
    var priority: Int
    var secondaryPriority: Int
    var sortPriority: Int
    var tileOrder: Int
    var stableOrderKey: UInt64

    init(priority: Int, secondaryPriority: Int, sortPriority: Int, tileOrder: Int = 0, stableOrderKey: UInt64) {
        self.priority = priority
        self.secondaryPriority = secondaryPriority
        self.sortPriority = sortPriority
        self.tileOrder = tileOrder
        self.stableOrderKey = stableOrderKey
    }

    init(candidate: ScreenCollisionCandidate, tileOrder: Int) {
        self.init(priority: candidate.priority,
                  secondaryPriority: candidate.secondaryPriority,
                  sortPriority: candidate.sortPriority,
                  tileOrder: tileOrder,
                  stableOrderKey: candidate.stableOrderKey)
    }

    /// Strict order: whoever is placed first keeps the space.
    static func precedes(_ lhs: LabelCollisionRank, _ rhs: LabelCollisionRank) -> Bool {
        if lhs.priority != rhs.priority {
            return lhs.priority < rhs.priority
        }
        if lhs.secondaryPriority != rhs.secondaryPriority {
            return lhs.secondaryPriority < rhs.secondaryPriority
        }
        if lhs.sortPriority != rhs.sortPriority {
            return lhs.sortPriority < rhs.sortPriority
        }
        if lhs.tileOrder != rhs.tileOrder {
            return lhs.tileOrder < rhs.tileOrder
        }
        return lhs.stableOrderKey < rhs.stableOrderKey
    }
}

/// A road label instance offered to the solver: its glyph boxes are a
/// range of the solver's road box arrays, and the whole instance is
/// accepted or rejected as one.
struct LabelCollisionRoadItem {
    var rank: LabelCollisionRank
    var groupId: UInt64
    var boxRange: Range<Int>
    /// The instance's index in the road label set, where its decision lands
    /// in `roadVisible`.
    var targetIndex: Int
}

/// The frame's label collision solve: every candidate, base labels and
/// road instances together, in one strict rank order, each accepted when
/// none of its boxes overlaps a box already placed by an earlier one. One
/// pass, no budget, no seeding, no eviction: the decision for a pose is a
/// pure function of the pose, and the fades smooth the changes between
/// frames.
///
/// The same feature reaches the set from several tiles (an exact tile and
/// the coarser one standing in beside it, or two world wraps), each copy
/// with the feature's key as its group. The copies stand at one point, so
/// they overlap: a base label that overlaps a placed box of its own group
/// is not blocked but found to be that box's duplicate, and reported as
/// such, so the caller can hand its fade to the winner and hide it. A road
/// instance's own glyphs share its group so they never block each other.
///
/// The base labels' ranks and order are fixed at `rebindBase` (a topology
/// change); the road instances are few and are sorted per solve into a
/// reused array and merged with the base order. The grid is a bucket per
/// cell with intrusive lists over flat buffers, all kept between frames and
/// emptied with the capacity intact, so a solve allocates nothing once
/// the buffers have grown to the frame's size.
final class LabelCollisionSolver {
    private var baseRanks: [LabelCollisionRank] = []
    /// Base label indices in rank order.
    private var baseOrder: [Int] = []

    private var roadOrder: [Int] = []

    private var gridWidth = 0
    private var gridHeight = 0
    private var cellSizePx: Float = 64
    private let cellHeads = CollisionScratchBuffer<Int32>(capacity: 4096)
    private let nodeNext = CollisionScratchBuffer<Int32>(capacity: 4096)
    private let nodeBox = CollisionScratchBuffer<Int32>(capacity: 4096)
    private let placedMin = CollisionScratchBuffer<SIMD2<Float>>(capacity: 1024)
    private let placedMax = CollisionScratchBuffer<SIMD2<Float>>(capacity: 1024)
    private let placedGroup = CollisionScratchBuffer<UInt64>(capacity: 1024)
    /// The base label a placed box belongs to, -1 for a road glyph.
    private let placedOwner = CollisionScratchBuffer<Int32>(capacity: 1024)
    /// The boxes of the item being tested, accepted only all together.
    private let pendingMin = CollisionScratchBuffer<SIMD2<Float>>(capacity: 64)
    private let pendingMax = CollisionScratchBuffer<SIMD2<Float>>(capacity: 64)
    private let pendingCells = CollisionScratchBuffer<SIMD4<Int32>>(capacity: 64)

    private enum Offer {
        case accepted
        case blocked
        /// The box stands on a placed box of its own group: the base label
        /// that owns that box.
        case duplicate(Int32)
    }

    var baseCount: Int {
        baseRanks.count
    }

    /// The base labels' ranks, in the working set's index order. Sorted
    /// once here; the sort is the only allocation of the solver's life
    /// besides growth.
    func rebindBase(ranks: [LabelCollisionRank]) {
        baseRanks = ranks
        baseOrder = Array(ranks.indices)
        baseOrder.sort { LabelCollisionRank.precedes(ranks[$0], ranks[$1]) }
    }

    /// Solves the frame. `baseCenters`, `baseHalfSizes` and `baseEnabled`
    /// are index-aligned with the base set (a disabled label takes no space
    /// and is hidden); `baseGroupIds` is each label's key, the group its
    /// copies share. Road boxes are the instances' glyph boxes
    /// (`roadItems` ranges into `roadCenters`/`roadHalfSizes`).
    /// Writes `baseVisible` (index-aligned with the base set),
    /// `baseDuplicateOf` (index-aligned with the base set: the index of the
    /// placed copy a label is a duplicate of, -1 otherwise) and
    /// `roadVisible` (index-aligned with the road instance set, sized by
    /// the caller; an instance not offered keeps the value it had) in place.
    func solve(viewportSize: SIMD2<Float>,
               cellSizePx: Float,
               baseCenters: [SIMD2<Float>],
               baseHalfSizes: [SIMD2<Float>],
               baseEnabled: [Bool],
               baseGroupIds: [UInt64],
               roadItems: [LabelCollisionRoadItem],
               roadCenters: [SIMD2<Float>],
               roadHalfSizes: [SIMD2<Float>],
               baseVisible: inout [Bool],
               baseDuplicateOf: inout [Int32],
               roadVisible: inout [Bool]) {
        resetGrid(viewportSize: viewportSize, cellSizePx: cellSizePx)
        let baseCount = baseRanks.count
        if baseVisible.count != baseCount {
            baseVisible = [Bool](repeating: false, count: baseCount)
        }
        if baseDuplicateOf.count != baseCount {
            baseDuplicateOf = [Int32](repeating: -1, count: baseCount)
        }

        roadOrder.removeAll(keepingCapacity: true)
        roadOrder.append(contentsOf: roadItems.indices)
        roadOrder.sort { LabelCollisionRank.precedes(roadItems[$0].rank, roadItems[$1].rank) }

        let baseTotal = min(baseOrder.count, min(baseCenters.count, min(baseHalfSizes.count, baseEnabled.count)))
        let roadTotal = roadOrder.count
        baseOrder.withUnsafeBufferPointer { baseOrder in
        baseRanks.withUnsafeBufferPointer { baseRanks in
        baseCenters.withUnsafeBufferPointer { baseCenters in
        baseHalfSizes.withUnsafeBufferPointer { baseHalfSizes in
        baseEnabled.withUnsafeBufferPointer { baseEnabled in
        baseGroupIds.withUnsafeBufferPointer { baseGroupIds in
        roadOrder.withUnsafeBufferPointer { roadOrder in
        roadItems.withUnsafeBufferPointer { roadItems in
        roadCenters.withUnsafeBufferPointer { roadCenters in
        roadHalfSizes.withUnsafeBufferPointer { roadHalfSizes in
        baseVisible.withUnsafeMutableBufferPointer { baseVisible in
        baseDuplicateOf.withUnsafeMutableBufferPointer { baseDuplicateOf in
        roadVisible.withUnsafeMutableBufferPointer { roadVisible in
            var baseCursor = 0
            var roadCursor = 0
            while baseCursor < baseTotal || roadCursor < roadTotal {
                let takeBase: Bool
                if baseCursor < baseTotal, roadCursor < roadTotal {
                    takeBase = LabelCollisionRank.precedes(baseRanks[baseOrder[baseCursor]],
                                                           roadItems[roadOrder[roadCursor]].rank)
                } else {
                    takeBase = baseCursor < baseTotal
                }
                if takeBase {
                    let index = baseOrder[baseCursor]
                    baseCursor += 1
                    baseDuplicateOf[index] = -1
                    guard baseEnabled[index] else {
                        baseVisible[index] = false
                        continue
                    }
                    let groupId = index < baseGroupIds.count ? baseGroupIds[index] : 0
                    pendingMin.removeAll()
                    pendingMax.removeAll()
                    pendingCells.removeAll()
                    switch offer(center: baseCenters[index], halfSize: baseHalfSizes[index], groupId: groupId, findsDuplicates: true) {
                    case .accepted:
                        let accepted = pendingMin.count > 0
                        if accepted {
                            commitPending(groupId: groupId, owner: Int32(index))
                        }
                        baseVisible[index] = accepted
                    case .blocked:
                        baseVisible[index] = false
                    case .duplicate(let winner):
                        baseVisible[index] = false
                        baseDuplicateOf[index] = winner
                    }
                } else {
                    let itemIndex = roadOrder[roadCursor]
                    roadCursor += 1
                    let item = roadItems[itemIndex]
                    pendingMin.removeAll()
                    pendingMax.removeAll()
                    pendingCells.removeAll()
                    var accepted = item.boxRange.isEmpty == false
                    var boxIndex = item.boxRange.lowerBound
                    while accepted, boxIndex < item.boxRange.upperBound {
                        guard boxIndex < roadCenters.count, boxIndex < roadHalfSizes.count else {
                            accepted = false
                            break
                        }
                        switch offer(center: roadCenters[boxIndex], halfSize: roadHalfSizes[boxIndex], groupId: item.groupId, findsDuplicates: false) {
                        case .accepted:
                            break
                        case .blocked, .duplicate:
                            accepted = false
                        }
                        boxIndex += 1
                    }
                    accepted = accepted && pendingMin.count > 0
                    if accepted {
                        commitPending(groupId: item.groupId, owner: -1)
                    }
                    if item.targetIndex >= 0, item.targetIndex < roadVisible.count {
                        roadVisible[item.targetIndex] = accepted
                    }
                }
            }
        }}}}}}}}}}}}}
    }

    // MARK: - Grid

    private func resetGrid(viewportSize: SIMD2<Float>, cellSizePx: Float) {
        self.cellSizePx = max(1, cellSizePx)
        gridWidth = max(1, Int(ceil(max(1, viewportSize.x) / self.cellSizePx)))
        gridHeight = max(1, Int(ceil(max(1, viewportSize.y) / self.cellSizePx)))
        cellHeads.reset(count: gridWidth * gridHeight, value: -1)
        nodeNext.removeAll()
        nodeBox.removeAll()
        placedMin.removeAll()
        placedMax.removeAll()
        placedGroup.removeAll()
        placedOwner.removeAll()
    }

    /// Tests one box against the placed ones and queues it for commit. A
    /// box entirely off screen is neither queued nor a collision. With
    /// `findsDuplicates`, a placed box of the same group under this one is
    /// the copy this box duplicates; without, it is ignored.
    @inline(__always)
    private func offer(center: SIMD2<Float>, halfSize: SIMD2<Float>, groupId: UInt64, findsDuplicates: Bool) -> Offer {
        let boxMin = center - halfSize
        let boxMax = center + halfSize
        let viewportWidth = Float(gridWidth) * cellSizePx
        let viewportHeight = Float(gridHeight) * cellSizePx
        if boxMax.x < 0 || boxMax.y < 0 || boxMin.x > viewportWidth || boxMin.y > viewportHeight {
            return .accepted
        }
        let minCellX = min(max(Int(max(0, boxMin.x) / cellSizePx), 0), gridWidth - 1)
        let maxCellX = min(max(Int(min(viewportWidth, boxMax.x) / cellSizePx), 0), gridWidth - 1)
        let minCellY = min(max(Int(max(0, boxMin.y) / cellSizePx), 0), gridHeight - 1)
        let maxCellY = min(max(Int(min(viewportHeight, boxMax.y) / cellSizePx), 0), gridHeight - 1)

        let heads = cellHeads.pointer
        let next = nodeNext.pointer
        let boxes = nodeBox.pointer
        let mins = placedMin.pointer
        let maxs = placedMax.pointer
        let groups = placedGroup.pointer
        let owners = placedOwner.pointer
        var cellY = minCellY
        while cellY <= maxCellY {
            let row = cellY * gridWidth
            var cellX = minCellX
            while cellX <= maxCellX {
                var node = heads[row + cellX]
                while node >= 0 {
                    let box = Int(boxes[Int(node)])
                    let otherMin = mins[box]
                    let otherMax = maxs[box]
                    if boxMin.x < otherMax.x && boxMax.x > otherMin.x && boxMin.y < otherMax.y && boxMax.y > otherMin.y {
                        if groupId == 0 || groups[box] != groupId {
                            return .blocked
                        }
                        if findsDuplicates, owners[box] >= 0 {
                            return .duplicate(owners[box])
                        }
                    }
                    node = next[Int(node)]
                }
                cellX += 1
            }
            cellY += 1
        }
        // The item's own earlier boxes: a road label's glyphs are one group,
        // so they never block each other, matching the placed-box rule.
        pendingMin.append(boxMin)
        pendingMax.append(boxMax)
        pendingCells.append(SIMD4<Int32>(Int32(minCellX), Int32(maxCellX), Int32(minCellY), Int32(maxCellY)))
        return .accepted
    }

    @inline(__always)
    private func commitPending(groupId: UInt64, owner: Int32) {
        var pendingIndex = 0
        while pendingIndex < pendingMin.count {
            let box = Int32(placedMin.count)
            placedMin.append(pendingMin[pendingIndex])
            placedMax.append(pendingMax[pendingIndex])
            placedGroup.append(groupId)
            placedOwner.append(owner)
            let cells = pendingCells[pendingIndex]
            var cellY = Int(cells.z)
            while cellY <= Int(cells.w) {
                let row = cellY * gridWidth
                var cellX = Int(cells.x)
                while cellX <= Int(cells.y) {
                    let cell = row + cellX
                    let node = Int32(nodeNext.count)
                    nodeNext.append(cellHeads[cell])
                    nodeBox.append(box)
                    cellHeads[cell] = node
                    cellX += 1
                }
                cellY += 1
            }
            pendingIndex += 1
        }
    }
}
