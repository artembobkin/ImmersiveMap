// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The rank a base label competes with in the collision solve, lower
/// first: its collision priority, then its sort priority, then its key.
/// All three come from the label itself, fixed when its tile is parsed,
/// never from the tile set it is in, so a tile's labels are ranked once
/// (`TileBuffers.TextLabelSet.rankOrder`) and a set's order is its tiles'
/// orders merged (`BaseLabelRankOrder`).
///
/// The two priorities are packed into one number, the collision priority
/// in the high half: two labels are compared by it alone, and by the key
/// only when it ties.
struct BaseLabelRank: Equatable {
    let packedPriorities: UInt64
    let key: UInt64

    init(priority: Int, sortPriority: Int, key: UInt64) {
        self.packedPriorities = Self.orderPreservingBits(priority) << 32 | Self.orderPreservingBits(sortPriority)
        self.key = key
    }

    init(placementMeta: LabelPlacementMeta) {
        self.init(priority: placementMeta.collisionPriority,
                  sortPriority: placementMeta.sortKey,
                  key: placementMeta.key)
    }

    /// The collision priority the rank was made with, clamped to 32 bits.
    var priority: Int {
        Int(Int32(bitPattern: UInt32(truncatingIfNeeded: packedPriorities >> 32) ^ 0x8000_0000))
    }

    @inline(__always)
    static func precedes(_ lhs: BaseLabelRank, _ rhs: BaseLabelRank) -> Bool {
        if lhs.packedPriorities != rhs.packedPriorities {
            return lhs.packedPriorities < rhs.packedPriorities
        }
        return lhs.key < rhs.key
    }

    /// `value` clamped to 32 bits with its sign bit flipped: unsigned
    /// order is then signed order.
    private static func orderPreservingBits(_ value: Int) -> UInt64 {
        UInt64(UInt32(bitPattern: Int32(clamping: value)) ^ 0x8000_0000)
    }
}

/// Orders of base labels by rank (`BaseLabelRank`).
enum BaseLabelRankOrder {
    /// The indices of `ranks` in rank order. Ties keep their index order.
    static func sorted(_ ranks: [BaseLabelRank]) -> [Int32] {
        var order = (0..<Int32(ranks.count)).map { $0 }
        ranks.withUnsafeBufferPointer { ranks in
            order.sort { lhs, rhs in
                let left = ranks[Int(lhs)]
                let right = ranks[Int(rhs)]
                return BaseLabelRank.precedes(left, right) || (left == right && lhs < rhs)
            }
        }
        return order
    }

    /// Merges `order`, whose `runs` are each in rank order and lie end to
    /// end from its start (anything after the last is one more run), into
    /// one rank order in place: adjacent runs are
    /// merged pairwise until one is left, so a set of k runs takes about
    /// log2(k) passes over it. `ranks` is read by the indices `order`
    /// holds. Ties keep the earlier run first.
    static func mergeRuns(_ order: inout [Int32], runs: [Range<Int>], ranks: [BaseLabelRank]) {
        var bounds: [Int] = []
        bounds.reserveCapacity(runs.count + 1)
        bounds.append(0)
        for run in runs where run.isEmpty == false {
            bounds.append(run.upperBound)
        }
        // Whatever follows the last run is one more run.
        if let last = bounds.last, last < order.count {
            bounds.append(order.count)
        }
        guard bounds.count > 2 else {
            return
        }
        var scratch = [Int32](repeating: 0, count: order.count)
        var nextBounds: [Int] = []
        nextBounds.reserveCapacity(bounds.count)
        ranks.withUnsafeBufferPointer { ranks in
            while bounds.count > 2 {
                nextBounds.removeAll(keepingCapacity: true)
                nextBounds.append(0)
                order.withUnsafeBufferPointer { source in
                    scratch.withUnsafeMutableBufferPointer { target in
                        var pair = 0
                        while pair + 1 < bounds.count {
                            let start = bounds[pair]
                            // A last run without a partner is copied as it is.
                            let middle = bounds[pair + 1]
                            let end = pair + 2 < bounds.count ? bounds[pair + 2] : middle
                            var left = start
                            var right = middle
                            var out = start
                            while left < middle, right < end {
                                if BaseLabelRank.precedes(ranks[Int(source[right])], ranks[Int(source[left])]) {
                                    target[out] = source[right]
                                    right += 1
                                } else {
                                    target[out] = source[left]
                                    left += 1
                                }
                                out += 1
                            }
                            while left < middle {
                                target[out] = source[left]
                                left += 1
                                out += 1
                            }
                            while right < end {
                                target[out] = source[right]
                                right += 1
                                out += 1
                            }
                            nextBounds.append(end)
                            pair += 2
                        }
                    }
                }
                swap(&order, &scratch)
                swap(&bounds, &nextBounds)
            }
        }
    }
}
