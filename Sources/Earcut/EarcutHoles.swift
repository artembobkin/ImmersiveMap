// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT
//
// Part of the mapbox/earcut port. The ISC notice heads EarcutCore.swift.

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

        // Process holes from left to right. The pool index breaks the ties
        // `compareXYSlope` leaves, so the ordering (and with it the output)
        // is the one the reference implementation's stable sort keeps,
        // deterministic under Swift's unstable sort.
        queue.sort { lhs, rhs in
            let order = compareXYSlope(lhs, rhs)
            if order != 0 { return order < 0 }
            return lhs < rhs
        }

        // Block-bbox index for findHoleBridge, grown append-only as holes
        // merge (see EarcutHoleBridgeIndex.swift). Seed it with the outer
        // ring, then append each merged hole.
        buildBlockIndex(maxNodes: data.count / dim, numHoles: holeIndices.count)
        indexSegment(head: outerNode, stop: outerNode)

        // `indexActive` lets removeNode keep the block boxes live as
        // filterPoints heals edges during merges (see growBlock).
        indexActive = true
        for hole in queue {
            outerNode = eliminateHole(hole: hole, outerNode: outerNode)
        }
        indexActive = false

        // Collapse collinear/coincident points across the whole merged ring
        // once before clipping.
        return filterPoints(start: outerNode)
    }

    /// Orders hole start points by x, then y, then by the slope of the
    /// edge leaving them: when the leftmost points of two holes meet at a
    /// vertex, the holes are sorted counterclockwise so that the bridge to
    /// the outer shell is always the point they meet at. Negative when
    /// `a` comes first, zero for a tie (a slope difference that is not a
    /// number, from a vertical or zero-length edge, counts as a tie the way
    /// the reference's comparator does).
    private func compareXYSlope(_ a: Int32, _ b: Int32) -> Double {
        let aNode = nodes[Int(a)]
        let bNode = nodes[Int(b)]
        if aNode.x != bNode.x { return aNode.x - bNode.x }
        if aNode.y != bNode.y { return aNode.y - bNode.y }
        let aNext = nodes[Int(aNode.next)]
        let bNext = nodes[Int(bNode.next)]
        let slopes = (aNext.y - aNode.y) / (aNext.x - aNode.x)
            - (bNext.y - bNode.y) / (bNext.x - bNode.x)
        return slopes.isNaN ? 0 : slopes
    }

    /// Finds a bridge between vertices that connects a hole with the outer
    /// ring, and links it.
    private func eliminateHole(hole: Int32, outerNode: Int32) -> Int32 {
        let bridge = findHoleBridge(hole: hole, outerNode: outerNode)
        guard bridge != Self.nilIndex else {
            return outerNode
        }

        let bridgeReverse = splitPolygon(bridge, hole)

        // Index the merged-in segment before filtering: in ring order the
        // splice runs bridge -> hole -> bridgeReverse -> bridge2 -> (bridge's
        // old next), covering the hole's edges and both new slit edges.
        // filterPoints below only drops collinear/coincident points, so these
        // boxes stay valid (conservative) supersets.
        let bridge2 = nodes[Int(bridgeReverse)].next
        indexSegment(head: bridge, stop: nodes[Int(bridge2)].next)

        // Heal collinear/coincident points around the two new slit edges.
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
        // to the left. The segment's endpoint with lesser x is a potential
        // connection point, unless they intersect at a vertex, then choose
        // the vertex.
        if equals(hole, p) { return p }

        // Scan blocks, skipping any whose box can't hold a crossing that
        // beats qx and lies left of hx (the prune Morton order can't express:
        // explicit per-axis [minY, maxY] / [minX, maxX]).
        for b in 0..<numBlocks {
            let g = b * 4
            if hy < blockBBox[g + 1] || hy > blockBBox[g + 3] || blockBBox[g] > hx || blockBBox[g + 2] <= qx {
                continue
            }

            // Ensure the walk's exclusive bound is live so we don't overrun
            // into other blocks.
            let stop = liveBlockStop(b)

            p = liveBlockHead(b)
            repeat {
                let node = nodes[Int(p)]
                // Skip nodes removed by filterPoints (stale in the index).
                if nodes[Int(node.prev)].next == p {
                    let next = nodes[Int(node.next)]
                    if equals(hole, node.next) {
                        return node.next
                    } else if hy <= node.y, hy >= next.y, next.y != node.y {
                        let x = node.x + (hy - node.y) * (next.x - node.x) / (next.y - node.y)
                        if x <= hx, x > qx {
                            qx = x
                            m = node.x < next.x ? p : node.next
                            if x == hx {
                                // The hole touches the outer segment, so
                                // pick the leftmost endpoint.
                                return m
                            }
                        }
                    }
                }
                p = node.next
            } while p != stop
        }

        guard m != Self.nilIndex else { return Self.nilIndex }

        // Look for points inside the triangle of the hole point, the segment
        // intersection, and the endpoint. If there are none, the connection is
        // valid. Otherwise choose the point of the minimum angle with the ray
        // as the connection point.
        let mx = nodes[Int(m)].x
        let my = nodes[Int(m)].y
        // The triangle's y span. Its x span is [mx, hx].
        let tminY = min(hy, my)
        let tmaxY = max(hy, my)
        var tanMin = Double.infinity

        // Scan the same blocks, skipping any whose box can't overlap the
        // triangle's [mx, hx] x [tminY, tmaxY] box.
        for b in 0..<numBlocks {
            let g = b * 4
            if blockBBox[g + 2] < mx || blockBBox[g] > hx || blockBBox[g + 3] < tminY || blockBBox[g + 1] > tmaxY {
                continue
            }

            let stop = liveBlockStop(b)

            p = liveBlockHead(b)
            repeat {
                let node = nodes[Int(p)]
                if nodes[Int(node.prev)].next == p, hx >= node.x, node.x >= mx, hx != node.x,
                   pointInTriangle(hy < my ? hx : qx, hy,
                                   mx, my,
                                   hy < my ? qx : hx, hy,
                                   node.x, node.y) {
                    let tan = abs(hy - node.y) / (hx - node.x)
                    let next = nodes[Int(node.next)]

                    // If the hole point sits on p's horizontal edge (a
                    // T-junction touch) the bridge runs along that edge:
                    // locallyInside rejects it as collinear, but it's valid.
                    if locallyInside(p, hole) || (node.y == hy && next.y == hy && next.x > hx),
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
        }

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
