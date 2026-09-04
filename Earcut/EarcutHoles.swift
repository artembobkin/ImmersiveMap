// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT
//
// Part of the mapbox/earcut port; the ISC notice heads EarcutCore.swift and
// is repeated in THIRD-PARTY-NOTICES.md at the repository root.

// Turning a polygon with holes into a single ring: every hole is bridged
// into the outer loop, left to right.
extension EarcutCore {
    /// Links every hole into the outer loop, producing a single-ring polygon
    /// without holes.
    func eliminateHoles(holeIndices: [Int], outerNode providedOuterNode: Int32) -> Int32 {
        var outerNode = providedOuterNode
        var queue: [Int32] = []
        queue.reserveCapacity(holeIndices.count)

        for holeNumber in 0..<holeIndices.count {
            let start = holeIndices[holeNumber] * dim
            let end = holeNumber < holeIndices.count - 1 ? holeIndices[holeNumber + 1] * dim : data.count
            let list = linkedList(start: start, end: end, clockwise: false)
            guard list != Self.nilIndex else { continue }
            if list == nodes[Int(list)].next {
                nodes[Int(list)].steiner = true
            }
            queue.append(getLeftmost(list))
        }

        // Process holes from left to right; y then pool index break x ties so
        // the ordering (and with it the output) is deterministic under
        // Swift's unstable sort.
        queue.sort { lhs, rhs in
            let lhsNode = nodes[Int(lhs)]
            let rhsNode = nodes[Int(rhs)]
            if lhsNode.x != rhsNode.x { return lhsNode.x < rhsNode.x }
            if lhsNode.y != rhsNode.y { return lhsNode.y < rhsNode.y }
            return lhs < rhs
        }

        for hole in queue {
            outerNode = eliminateHole(hole: hole, outerNode: outerNode)
        }

        return outerNode
    }

    /// Finds a bridge between vertices that connects a hole with the outer
    /// ring, and links it.
    private func eliminateHole(hole: Int32, outerNode: Int32) -> Int32 {
        let bridge = findHoleBridge(hole: hole, outerNode: outerNode)
        guard bridge != Self.nilIndex else {
            return outerNode
        }

        let bridgeReverse = splitPolygon(bridge, hole)

        // Filter collinear points around the cuts.
        _ = filterPoints(start: bridgeReverse, end: nodes[Int(bridgeReverse)].next)
        return filterPoints(start: bridge, end: nodes[Int(bridge)].next)
    }

    /// David Eberly's algorithm for finding a bridge between a hole and the
    /// outer polygon.
    private func findHoleBridge(hole: Int32, outerNode: Int32) -> Int32 {
        var p = outerNode
        let hx = nodes[Int(hole)].x
        let hy = nodes[Int(hole)].y
        var qx = -Double.infinity
        var m = Self.nilIndex

        // Find a segment intersected by a ray from the hole's leftmost point
        // to the left; the segment's endpoint with lesser x is a potential
        // connection point.
        repeat {
            let node = nodes[Int(p)]
            let next = nodes[Int(node.next)]
            if hy <= node.y, hy >= next.y, next.y != node.y {
                let x = node.x + (hy - node.y) * (next.x - node.x) / (next.y - node.y)
                if x <= hx, x > qx {
                    qx = x
                    m = node.x < next.x ? p : node.next
                    if x == hx {
                        // The hole touches the outer segment; pick the
                        // leftmost endpoint.
                        return m
                    }
                }
            }
            p = node.next
        } while p != outerNode

        guard m != Self.nilIndex else { return Self.nilIndex }

        // Look for points inside the triangle of the hole point, the segment
        // intersection, and the endpoint; if there are none, the connection is
        // valid. Otherwise choose the point of the minimum angle with the ray
        // as the connection point.
        let stop = m
        let mxInitial = nodes[Int(m)].x
        let myInitial = nodes[Int(m)].y
        var tanMin = Double.infinity

        p = m

        repeat {
            let node = nodes[Int(p)]
            if hx >= node.x, node.x >= mxInitial, hx != node.x,
               pointInTriangle(hy < myInitial ? hx : qx, hy,
                               mxInitial, myInitial,
                               hy < myInitial ? qx : hx, hy,
                               node.x, node.y) {
                let tan = abs(hy - node.y) / (hx - node.x)

                if locallyInside(p, hole),
                   tan < tanMin
                    || (tan == tanMin
                        && (node.x > nodes[Int(m)].x
                            || (node.x == nodes[Int(m)].x && sectorContainsSector(m, p)))) {
                    m = p
                    tanMin = tan
                }
            }
            p = node.next
        } while p != stop

        return m
    }

    /// Whether the sector in vertex m contains the sector in vertex p in the
    /// same coordinates.
    private func sectorContainsSector(_ m: Int32, _ p: Int32) -> Bool {
        area(nodes[Int(m)].prev, m, nodes[Int(p)].prev) < 0
            && area(nodes[Int(p)].next, m, nodes[Int(m)].next) < 0
    }

    /// Finds the leftmost node of a polygon ring.
    private func getLeftmost(_ start: Int32) -> Int32 {
        var p = start
        var leftmost = start
        repeat {
            let node = nodes[Int(p)]
            let leftmostNode = nodes[Int(leftmost)]
            if node.x < leftmostNode.x || (node.x == leftmostNode.x && node.y < leftmostNode.y) {
                leftmost = p
            }
            p = node.next
        } while p != start
        return leftmost
    }
}
