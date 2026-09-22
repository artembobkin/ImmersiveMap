// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

/// The rank a label competes with: lower wins. Ties fall to the stable key.
struct LabelCollisionRank: Equatable {
    var priority: Int
    var secondaryPriority: Int
    var sortPriority: Int
    var stableOrderKey: UInt64

    init(priority: Int, secondaryPriority: Int, sortPriority: Int, stableOrderKey: UInt64) {
        self.priority = priority
        self.secondaryPriority = secondaryPriority
        self.sortPriority = sortPriority
        self.stableOrderKey = stableOrderKey
    }

    init(candidate: ScreenCollisionCandidate) {
        self.init(priority: candidate.priority,
                  secondaryPriority: candidate.secondaryPriority,
                  sortPriority: candidate.sortPriority,
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
/// The base labels' ranks and order are fixed at `rebindBase` (a topology
/// change); the road instances are few and are sorted per solve into a
/// reused array and merged with the base order. The grid is a bucket per
/// cell with intrusive lists over flat arrays, all kept between frames and
/// emptied with the capacity intact, so a solve allocates nothing once
/// the arrays have grown to the frame's size.
final class LabelCollisionSolver {
    private var baseRanks: [LabelCollisionRank] = []
    /// Base label indices in rank order.
    private var baseOrder: [Int] = []

    private var roadOrder: [Int] = []

    private var gridWidth = 0
    private var gridHeight = 0
    private var cellSizePx: Float = 64
    private var cellHeads: [Int32] = []
    private var nodeNext: [Int32] = []
    private var nodeBox: [Int32] = []
    private var placedMin: [SIMD2<Float>] = []
    private var placedMax: [SIMD2<Float>] = []
    private var placedGroup: [UInt64] = []
    /// The boxes of the item being tested, accepted only all together.
    private var pendingMin: [SIMD2<Float>] = []
    private var pendingMax: [SIMD2<Float>] = []
    private var pendingCells: [(minX: Int, maxX: Int, minY: Int, maxY: Int)] = []

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
    /// and is hidden); `baseGroupIds` lets a label share a group with
    /// another so the two never collide. Road boxes are the instances'
    /// glyph boxes (`roadItems` ranges into `roadCenters`/`roadHalfSizes`).
    /// Writes `baseVisible` (index-aligned with the base set) and
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
               roadVisible: inout [Bool]) {
        resetGrid(viewportSize: viewportSize, cellSizePx: cellSizePx)
        if baseVisible.count != baseRanks.count {
            baseVisible = [Bool](repeating: false, count: baseRanks.count)
        }

        roadOrder.removeAll(keepingCapacity: true)
        roadOrder.append(contentsOf: roadItems.indices)
        roadOrder.sort { LabelCollisionRank.precedes(roadItems[$0].rank, roadItems[$1].rank) }

        var baseCursor = 0
        var roadCursor = 0
        let baseTotal = min(baseOrder.count, min(baseCenters.count, min(baseHalfSizes.count, baseEnabled.count)))
        while baseCursor < baseTotal || roadCursor < roadOrder.count {
            let takeBase: Bool
            if baseCursor < baseTotal, roadCursor < roadOrder.count {
                takeBase = LabelCollisionRank.precedes(baseRanks[baseOrder[baseCursor]],
                                                       roadItems[roadOrder[roadCursor]].rank)
            } else {
                takeBase = baseCursor < baseTotal
            }
            if takeBase {
                let index = baseOrder[baseCursor]
                baseCursor += 1
                guard baseEnabled[index] else {
                    baseVisible[index] = false
                    continue
                }
                let groupId = index < baseGroupIds.count ? baseGroupIds[index] : 0
                pendingMin.removeAll(keepingCapacity: true)
                pendingMax.removeAll(keepingCapacity: true)
                pendingCells.removeAll(keepingCapacity: true)
                let accepted = offer(center: baseCenters[index], halfSize: baseHalfSizes[index], groupId: groupId)
                    && pendingMin.isEmpty == false
                if accepted {
                    commitPending(groupId: groupId)
                }
                baseVisible[index] = accepted
            } else {
                let itemIndex = roadOrder[roadCursor]
                roadCursor += 1
                let item = roadItems[itemIndex]
                pendingMin.removeAll(keepingCapacity: true)
                pendingMax.removeAll(keepingCapacity: true)
                pendingCells.removeAll(keepingCapacity: true)
                var accepted = item.boxRange.isEmpty == false
                for boxIndex in item.boxRange where accepted {
                    guard boxIndex < roadCenters.count, boxIndex < roadHalfSizes.count else {
                        accepted = false
                        break
                    }
                    accepted = offer(center: roadCenters[boxIndex], halfSize: roadHalfSizes[boxIndex], groupId: item.groupId)
                }
                accepted = accepted && pendingMin.isEmpty == false
                if accepted {
                    commitPending(groupId: item.groupId)
                }
                if item.targetIndex >= 0, item.targetIndex < roadVisible.count {
                    roadVisible[item.targetIndex] = accepted
                }
            }
        }
    }

    // MARK: - Grid

    private func resetGrid(viewportSize: SIMD2<Float>, cellSizePx: Float) {
        self.cellSizePx = max(1, cellSizePx)
        gridWidth = max(1, Int(ceil(max(1, viewportSize.x) / self.cellSizePx)))
        gridHeight = max(1, Int(ceil(max(1, viewportSize.y) / self.cellSizePx)))
        let cellCount = gridWidth * gridHeight
        if cellHeads.count != cellCount {
            cellHeads = [Int32](repeating: -1, count: cellCount)
        } else {
            for index in cellHeads.indices {
                cellHeads[index] = -1
            }
        }
        nodeNext.removeAll(keepingCapacity: true)
        nodeBox.removeAll(keepingCapacity: true)
        placedMin.removeAll(keepingCapacity: true)
        placedMax.removeAll(keepingCapacity: true)
        placedGroup.removeAll(keepingCapacity: true)
    }

    /// Tests one box against the placed ones and queues it for commit.
    /// Returns false on a collision; a box entirely off screen is neither
    /// queued nor a collision.
    private func offer(center: SIMD2<Float>, halfSize: SIMD2<Float>, groupId: UInt64) -> Bool {
        let boxMin = center - halfSize
        let boxMax = center + halfSize
        let viewportWidth = Float(gridWidth) * cellSizePx
        let viewportHeight = Float(gridHeight) * cellSizePx
        if boxMax.x < 0 || boxMax.y < 0 || boxMin.x > viewportWidth || boxMin.y > viewportHeight {
            return true
        }
        let minCellX = min(max(Int(max(0, boxMin.x) / cellSizePx), 0), gridWidth - 1)
        let maxCellX = min(max(Int(min(viewportWidth, boxMax.x) / cellSizePx), 0), gridWidth - 1)
        let minCellY = min(max(Int(max(0, boxMin.y) / cellSizePx), 0), gridHeight - 1)
        let maxCellY = min(max(Int(min(viewportHeight, boxMax.y) / cellSizePx), 0), gridHeight - 1)

        for cellY in minCellY...maxCellY {
            for cellX in minCellX...maxCellX {
                var node = cellHeads[cellY * gridWidth + cellX]
                while node >= 0 {
                    let box = Int(nodeBox[Int(node)])
                    if groupId == 0 || placedGroup[box] != groupId {
                        let otherMin = placedMin[box]
                        let otherMax = placedMax[box]
                        if boxMin.x < otherMax.x && boxMax.x > otherMin.x && boxMin.y < otherMax.y && boxMax.y > otherMin.y {
                            return false
                        }
                    }
                    node = nodeNext[Int(node)]
                }
            }
        }
        // The item's own earlier boxes: a road label's glyphs are one group,
        // so they never block each other, matching the placed-box rule.
        pendingMin.append(boxMin)
        pendingMax.append(boxMax)
        pendingCells.append((minCellX, maxCellX, minCellY, maxCellY))
        return true
    }

    private func commitPending(groupId: UInt64) {
        for pendingIndex in pendingMin.indices {
            let box = Int32(placedMin.count)
            placedMin.append(pendingMin[pendingIndex])
            placedMax.append(pendingMax[pendingIndex])
            placedGroup.append(groupId)
            let cells = pendingCells[pendingIndex]
            for cellY in cells.minY...cells.maxY {
                for cellX in cells.minX...cells.maxX {
                    let cell = cellY * gridWidth + cellX
                    let node = Int32(nodeNext.count)
                    nodeNext.append(cellHeads[cell])
                    nodeBox.append(box)
                    cellHeads[cell] = node
                }
            }
        }
    }
}
