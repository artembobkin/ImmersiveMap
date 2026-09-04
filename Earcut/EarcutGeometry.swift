// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT
//
// Part of the mapbox/earcut port; the ISC notice heads EarcutCore.swift and
// is repeated in THIRD-PARTY-NOTICES.md at the repository root.

// The predicates the algorithm decides on: triangle area and containment,
// segment intersection, and whether a diagonal stays inside the polygon.
extension EarcutCore {
    func pointInTriangle(_ ax: Double, _ ay: Double,
                         _ bx: Double, _ by: Double,
                         _ cx: Double, _ cy: Double,
                         _ px: Double, _ py: Double) -> Bool {
        (cx - px) * (ay - py) >= (ax - px) * (cy - py)
            && (ax - px) * (by - py) >= (bx - px) * (ay - py)
            && (bx - px) * (cy - py) >= (cx - px) * (by - py)
    }

    /// Whether a diagonal between two polygon nodes is valid (lies in polygon
    /// interior).
    func isValidDiagonal(_ a: Int32, _ b: Int32) -> Bool {
        let aNode = nodes[Int(a)]
        let bNode = nodes[Int(b)]
        let doesNotIntersect = nodes[Int(aNode.next)].i != bNode.i
            && nodes[Int(aNode.prev)].i != bNode.i
            && intersectsPolygon(a, b) == false
        guard doesNotIntersect else { return false }

        let locallyVisible = locallyInside(a, b) && locallyInside(b, a) && middleInside(a, b)
            && (area(aNode.prev, a, bNode.prev) != 0 || area(a, bNode.prev, b) != 0)
        let zeroLengthCase = equals(a, b)
            && area(aNode.prev, a, aNode.next) > 0
            && area(bNode.prev, b, bNode.next) > 0
        return locallyVisible || zeroLengthCase
    }

    /// Signed area of a triangle.
    func area(_ p: Int32, _ q: Int32, _ r: Int32) -> Double {
        let pNode = nodes[Int(p)]
        let qNode = nodes[Int(q)]
        let rNode = nodes[Int(r)]
        return (qNode.y - pNode.y) * (rNode.x - qNode.x) - (qNode.x - pNode.x) * (rNode.y - qNode.y)
    }

    /// Whether two points are equal.
    func equals(_ a: Int32, _ b: Int32) -> Bool {
        nodes[Int(a)].x == nodes[Int(b)].x && nodes[Int(a)].y == nodes[Int(b)].y
    }

    /// Whether two segments intersect.
    func intersects(_ p1: Int32, _ q1: Int32, _ p2: Int32, _ q2: Int32) -> Bool {
        let o1 = sign(area(p1, q1, p2))
        let o2 = sign(area(p1, q1, q2))
        let o3 = sign(area(p2, q2, p1))
        let o4 = sign(area(p2, q2, q1))

        if o1 != o2 && o3 != o4 { return true } // general case

        if o1 == 0 && onSegment(p1, p2, q1) { return true }
        if o2 == 0 && onSegment(p1, q2, q1) { return true }
        if o3 == 0 && onSegment(p2, p1, q2) { return true }
        if o4 == 0 && onSegment(p2, q1, q2) { return true }

        return false
    }

    /// For collinear points p, q, r: whether q lies on segment pr.
    private func onSegment(_ p: Int32, _ q: Int32, _ r: Int32) -> Bool {
        let pNode = nodes[Int(p)]
        let qNode = nodes[Int(q)]
        let rNode = nodes[Int(r)]
        return qNode.x <= max(pNode.x, rNode.x) && qNode.x >= min(pNode.x, rNode.x)
            && qNode.y <= max(pNode.y, rNode.y) && qNode.y >= min(pNode.y, rNode.y)
    }

    private func sign(_ value: Double) -> Int {
        if value > 0 { return 1 }
        if value < 0 { return -1 }
        return 0
    }

    /// Whether the polygon diagonal intersects any polygon segments.
    private func intersectsPolygon(_ a: Int32, _ b: Int32) -> Bool {
        var p = a
        let aIndex = nodes[Int(a)].i
        let bIndex = nodes[Int(b)].i
        repeat {
            let node = nodes[Int(p)]
            let nextIndex = nodes[Int(node.next)].i
            if node.i != aIndex, nextIndex != aIndex, node.i != bIndex, nextIndex != bIndex,
               intersects(p, node.next, a, b) {
                return true
            }
            p = node.next
        } while p != a

        return false
    }

    /// Whether a polygon diagonal is locally inside the polygon.
    func locallyInside(_ a: Int32, _ b: Int32) -> Bool {
        let aNode = nodes[Int(a)]
        if area(aNode.prev, a, aNode.next) < 0 {
            return area(a, b, aNode.next) >= 0 && area(a, aNode.prev, b) >= 0
        }
        return area(a, b, aNode.prev) < 0 || area(a, aNode.next, b) < 0
    }

    /// Whether the middle point of a polygon diagonal is inside the polygon.
    private func middleInside(_ a: Int32, _ b: Int32) -> Bool {
        var p = a
        var inside = false
        let px = (nodes[Int(a)].x + nodes[Int(b)].x) / 2
        let py = (nodes[Int(a)].y + nodes[Int(b)].y) / 2
        repeat {
            let node = nodes[Int(p)]
            let next = nodes[Int(node.next)]
            if ((node.y > py) != (next.y > py)), next.y != node.y,
               px < (next.x - node.x) * (py - node.y) / (next.y - node.y) + node.x {
                inside.toggle()
            }
            p = node.next
        } while p != a

        return inside
    }
}
