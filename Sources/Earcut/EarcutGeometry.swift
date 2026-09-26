// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT
//
// Part of the mapbox/earcut port. The ISC notice heads EarcutCore.swift.

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
        // Degenerate case.
        let zeroLength = equals(a, b)
            && area(aNode.prev, a, aNode.next) > 0
            && area(bNode.prev, b, bNode.next) > 0
        guard nodes[Int(aNode.next)].i != bNode.i else { return false }
        // Locally visible, without opposite-facing sectors.
        guard zeroLength
                || (locallyInside(a, b) && locallyInside(b, a)
                    && (area(aNode.prev, a, bNode.prev) != 0 || area(a, bNode.prev, b) != 0)) else {
            return false
        }
        // Doesn't intersect other edges, and the diagonal is inside the
        // polygon.
        guard intersectsPolygon(a, b) == false else { return false }
        return zeroLength || middleInside(a, b)
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

    /// Whether two segments intersect. By default a collinear boundary
    /// touch counts as an intersection.
    func intersects(_ p1: Int32, _ q1: Int32, _ p2: Int32, _ q2: Int32, includeBoundary: Bool = true) -> Bool {
        let o1 = area(p1, q1, p2)
        let o2 = area(p1, q1, q2)
        let o3 = area(p2, q2, p1)
        let o4 = area(p2, q2, q1)

        // General case.
        if ((o1 > 0 && o2 < 0) || (o1 < 0 && o2 > 0)) && ((o3 > 0 && o4 < 0) || (o3 < 0 && o4 > 0)) {
            return true
        }

        if includeBoundary == false { return false }

        if o1 == 0 && onSegment(p1, p2, q1) { return true } // p1, q1 and p2 are collinear and p2 lies on p1q1
        if o2 == 0 && onSegment(p1, q2, q1) { return true } // p1, q1 and q2 are collinear and q2 lies on p1q1
        if o3 == 0 && onSegment(p2, p1, q2) { return true } // p2, q2 and p1 are collinear and p1 lies on p2q2
        if o4 == 0 && onSegment(p2, q1, q2) { return true } // p2, q2 and q1 are collinear and q1 lies on p2q2

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

    /// Whether the polygon diagonal intersects any polygon segments.
    private func intersectsPolygon(_ a: Int32, _ b: Int32) -> Bool {
        let aNode = nodes[Int(a)]
        let bNode = nodes[Int(b)]
        // Diagonal bbox. An edge whose bbox can't overlap it can't intersect
        // it, so skip the orientation test for those (the common case: the
        // diagonal is short).
        let minX = min(aNode.x, bNode.x)
        let maxX = max(aNode.x, bNode.x)
        let minY = min(aNode.y, bNode.y)
        let maxY = max(aNode.y, bNode.y)

        var p = a
        repeat {
            let node = nodes[Int(p)]
            let n = node.next
            let nNode = nodes[Int(n)]
            if (node.x > maxX && nNode.x > maxX) || (node.x < minX && nNode.x < minX)
                || (node.y > maxY && nNode.y > maxY) || (node.y < minY && nNode.y < minY) {
                p = n
                continue
            }
            if node.i != aNode.i, nNode.i != aNode.i, node.i != bNode.i, nNode.i != bNode.i,
               intersects(p, n, a, b) {
                return true
            }
            p = n
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
            if (node.y > py) != (next.y > py),
               px < (next.x - node.x) * (py - node.y) / (next.y - node.y) + node.x {
                inside.toggle()
            }
            p = node.next
        } while p != a

        return inside
    }
}
