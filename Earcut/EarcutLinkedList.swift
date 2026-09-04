// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT
//
// Part of the mapbox/earcut port; the ISC notice heads EarcutCore.swift and
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

    /// Eliminates colinear or duplicate points.
    func filterPoints(start: Int32, end providedEnd: Int32 = EarcutCore.nilIndex) -> Int32 {
        guard start != Self.nilIndex else { return start }
        var end = providedEnd == Self.nilIndex ? start : providedEnd

        var p = start
        var again = false
        repeat {
            again = false
            let node = nodes[Int(p)]
            if node.steiner == false, equals(p, node.next) || area(node.prev, p, node.next) == 0 {
                removeNode(p)
                p = node.prev
                end = node.prev
                if p == nodes[Int(p)].next { break }
                again = true
            } else {
                p = node.next
            }
        } while again || p != end

        return end
    }
}
