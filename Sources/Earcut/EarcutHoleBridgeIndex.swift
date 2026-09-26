// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT
//
// Part of the mapbox/earcut port. The ISC notice heads EarcutCore.swift.

// The block-bbox index for findHoleBridge (upstream issue #183): one
// [minX, minY, maxX, maxY] box per K consecutive ring edges, so the leftward
// ray scan can skip whole blocks in O(1) instead of walking the entire merged
// ring for every hole. Grown append-only: the outer ring seeds it, then each
// merged hole appends a segment (head node, stop node, K-blocks over
// head..stop). The segments are independent, not a tiling of the ring, since
// splices land mid-ring.
//
// filterPoints only drops collinear/coincident points, so a stale box stays
// a conservative superset of its live edges (never a false skip). The scans
// skip dead nodes (p.prev.next != p) and lazily advance a dead stop. Blocks
// are scanned in append (not ring) order, so the chosen bridge can differ
// from the un-indexed code: a different but equally valid result.
extension EarcutCore {
    /// Edges per block.
    private static let blockEdgeCount = 16

    var numBlocks: Int { blockHead.count }

    func buildBlockIndex(maxNodes: Int, numHoles: Int) {
        // Upper bound: every input node indexed once, +2 bridge nodes per
        // hole, plus a partial trailing block per appended segment (outer
        // ring + one per hole).
        let k = Self.blockEdgeCount
        let maxBlocks = (maxNodes + 2 * numHoles + k - 1) / k + numHoles + 2
        blockBBox.removeAll(keepingCapacity: true)
        blockHead.removeAll(keepingCapacity: true)
        blockStop.removeAll(keepingCapacity: true)
        blockBBox.reserveCapacity(maxBlocks * 4)
        blockHead.reserveCapacity(maxBlocks)
        blockStop.reserveCapacity(maxBlocks)
    }

    /// Indexes the ring run head..stop (exclusive) as ceil(len / K) blocks,
    /// where head == stop means the whole ring. Each block's box covers both
    /// endpoints of every edge it owns.
    func indexSegment(head: Int32, stop: Int32) {
        var p = head
        repeat {
            let b = Int32(blockHead.count)
            blockHead.append(p)
            var minX = Double.infinity, minY = Double.infinity
            var maxX = -Double.infinity, maxY = -Double.infinity
            var k = 0
            repeat {
                let node = nodes[Int(p)]
                // Edge p -> c. The box must bound both endpoints.
                let c = node.next
                let cNode = nodes[Int(c)]
                // Reuse z as the owning block during eliminateHoles (see
                // growBlock).
                nodes[Int(p)].z = b
                if node.x < minX { minX = node.x }
                if node.x > maxX { maxX = node.x }
                if node.y < minY { minY = node.y }
                if node.y > maxY { maxY = node.y }
                if cNode.x < minX { minX = cNode.x }
                if cNode.x > maxX { maxX = cNode.x }
                if cNode.y < minY { minY = cNode.y }
                if cNode.y > maxY { maxY = cNode.y }
                p = c
                k += 1
            } while k < Self.blockEdgeCount && p != stop
            blockStop.append(p)
            blockBBox.append(minX)
            blockBBox.append(minY)
            blockBBox.append(maxX)
            blockBBox.append(maxY)
        } while p != stop
    }

    /// When filterPoints heals an edge head -> tail (removing the collinear
    /// node between them), the healed edge can extend past head's frozen
    /// block box if its old far endpoint lived in another block. Growing
    /// head's block box to cover tail keeps the leftward ray prune from
    /// skipping it wrongly.
    func growBlock(head: Int32, tail: Int32) {
        let g = Int(nodes[Int(head)].z) * 4
        let tailNode = nodes[Int(tail)]
        if tailNode.x < blockBBox[g] { blockBBox[g] = tailNode.x }
        if tailNode.y < blockBBox[g + 1] { blockBBox[g + 1] = tailNode.y }
        if tailNode.x > blockBBox[g + 2] { blockBBox[g + 2] = tailNode.x }
        if tailNode.y > blockBBox[g + 3] { blockBBox[g + 3] = tailNode.y }
    }

    func liveBlockStop(_ b: Int) -> Int32 {
        var stop = blockStop[b]
        while nodes[Int(nodes[Int(stop)].prev)].next != stop {
            stop = nodes[Int(stop)].next
        }
        blockStop[b] = stop
        return stop
    }

    /// The block's head node can be removed by filterPoints during merges.
    /// Advancing it to the next live node keeps the walk from starting on
    /// (and immediately terminating at) a dead node. For the single full-ring seed
    /// block (head == stop) the same forward advance keeps them equal, so
    /// the repeat-while still laps the whole ring instead of collapsing to
    /// an empty walk.
    func liveBlockHead(_ b: Int) -> Int32 {
        var head = blockHead[b]
        while nodes[Int(nodes[Int(head)].prev)].next != head {
            head = nodes[Int(head)].next
        }
        blockHead[b] = head
        return head
    }
}
