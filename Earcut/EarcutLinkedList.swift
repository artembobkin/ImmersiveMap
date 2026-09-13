// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT
//
// Part of the mapbox/earcut port. The ISC notice heads EarcutCore.swift and
// is repeated in THIRD-PARTY-NOTICES.md at the repository root.

// Building the circular doubly linked rings the ear clipping walks, and
// pruning the vertices that carry no shape.
extension EarcutCore {
    /// Creates a circular doubly linked list from polygon points in the
    /// specified winding order.
    func linkedList(start: Int, end: Int, clockwise: Bool) -> Int32 {
        var last = Self.nilIndex

        if clockwise == (Earcut.signedArea(data: data, start: start, end: end, dim: dim) > 0) {
            var i = start
            while i < end {
                last = insertNode(i: Int32(i / dim), x: data[i], y: data[i + 1], last: last)
                i += dim
            }
        } else {
            var i = end - dim
            while i >= start {
                last = insertNode(i: Int32(i / dim), x: data[i], y: data[i + 1], last: last)
                i -= dim
            }
        }

        if last != Self.nilIndex, equals(last, nodes[Int(last)].next) {
            let next = nodes[Int(last)].next
            removeNode(last)
            last = next
        }

        return last
    }

    /// Removes collinear or coincident points. Whether a node can go depends
    /// only on its immediate neighbours, so the sweep runs forward and
    /// re-checks the predecessor after each removal. With no `end` it sweeps
    /// the whole ring, lapping until nothing is removable (the fixpoint the
    /// clipper needs). With an explicit `end` it heals only the dirty window
    /// around a bridge or diagonal cut, stopping at `end` rather than
    /// lapping: O(window) instead of O(ring).
    func filterPoints(start: Int32, end providedEnd: Int32 = EarcutCore.nilIndex) -> Int32 {
        guard start != Self.nilIndex else { return start }
        var end = providedEnd == Self.nilIndex ? start : providedEnd
        let full = end == start

        var p = start
        var again = false
        repeat {
            again = false
            let node = nodes[Int(p)]
            if p != node.next, node.steiner == false,
               equals(p, node.next) || area(node.prev, p, node.next) == 0 {
                // Pull the stop bound back past the removal.
                if full || p == end { end = node.prev }
                filteredOut = true
                removeNode(p)
                // Re-check the predecessor.
                p = node.prev
                again = true
            } else if full || p != end {
                p = node.next
                // Local heal: keep looping until the sweep reaches `end`.
                again = full == false
            }
        } while again || p != end

        return end
    }
}
