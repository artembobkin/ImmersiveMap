// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT
//
// Part of the mapbox/earcut port; the ISC notice heads EarcutCore.swift and
// is repeated in THIRD-PARTY-NOTICES.md at the repository root.

// Allocating nodes in the pool and relinking them: the only code that
// writes the prev/next and prevZ/nextZ fields.
extension EarcutCore {
    /// Links two polygon vertices with a bridge; if the vertices belong to the
    /// same ring, it splits the polygon into two; if one belongs to the outer
    /// ring and another to a hole, it merges them into a single ring.
    func splitPolygon(_ a: Int32, _ b: Int32) -> Int32 {
        let a2 = makeNode(i: nodes[Int(a)].i, x: nodes[Int(a)].x, y: nodes[Int(a)].y)
        let b2 = makeNode(i: nodes[Int(b)].i, x: nodes[Int(b)].x, y: nodes[Int(b)].y)
        let an = nodes[Int(a)].next
        let bp = nodes[Int(b)].prev

        nodes[Int(a)].next = b
        nodes[Int(b)].prev = a

        nodes[Int(a2)].next = an
        nodes[Int(an)].prev = a2

        nodes[Int(b2)].next = a2
        nodes[Int(a2)].prev = b2

        nodes[Int(bp)].next = b2
        nodes[Int(b2)].prev = bp

        return b2
    }

    /// Creates a node and optionally links it with the previous one (in a
    /// circular doubly linked list).
    func insertNode(i: Int32, x: Double, y: Double, last: Int32) -> Int32 {
        let p = makeNode(i: i, x: x, y: y)

        if last == Self.nilIndex {
            nodes[Int(p)].prev = p
            nodes[Int(p)].next = p
        } else {
            let lastNext = nodes[Int(last)].next
            nodes[Int(p)].next = lastNext
            nodes[Int(p)].prev = last
            nodes[Int(lastNext)].prev = p
            nodes[Int(last)].next = p
        }
        return p
    }

    func removeNode(_ p: Int32) {
        let node = nodes[Int(p)]
        nodes[Int(node.next)].prev = node.prev
        nodes[Int(node.prev)].next = node.next

        if node.prevZ != Self.nilIndex {
            nodes[Int(node.prevZ)].nextZ = node.nextZ
        }
        if node.nextZ != Self.nilIndex {
            nodes[Int(node.nextZ)].prevZ = node.prevZ
        }
    }

    private func makeNode(i: Int32, x: Double, y: Double) -> Int32 {
        let index = Int32(nodes.count)
        nodes.append(Node(x: x, y: y, i: i,
                          prev: Self.nilIndex, next: Self.nilIndex,
                          prevZ: Self.nilIndex, nextZ: Self.nilIndex,
                          z: 0, steiner: false))
        return index
    }
}
