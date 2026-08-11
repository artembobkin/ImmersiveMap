// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT
//
// Port of mapbox/earcut (https://github.com/mapbox/earcut), ISC license:
//   Copyright (c) 2016, Mapbox
//   Permission to use, copy, modify, and/or distribute this software for any
//   purpose with or without fee is hereby granted, provided that the above
//   copyright notice and this permission notice appear in all copies.
//
// The port keeps earcut.js function structure and naming for auditability, but
// stores nodes as plain structs in one contiguous pool linked by Int32 indices.
// The previous dependency (SwiftEarcut) modeled nodes as classes with `weak`
// back references, which made every linked-list hop in the ear-clipping loops
// pay ARC plus weak-table traffic; on an ocean polygon with dozens of island
// holes that was ~48 ms per tile. The flat pool triangulates the same input in
// well under a millisecond.

import Foundation

enum Earcut {
    /// Triangulates a polygon given as a flat coordinate array, with optional
    /// holes: `holeIndices` lists the vertex index at which each hole ring
    /// starts. Returns vertex indices where each consecutive triple forms one
    /// triangle.
    static func tessellate(data: [Double], holeIndices: [Int] = [], dim: Int = 2) -> [UInt32] {
        guard dim >= 2, data.count >= dim * 3 else { return [] }
        let core = EarcutCore(data: data, dim: dim)
        return core.run(holeIndices: holeIndices)
    }

    /// Relative difference between the triangulated area and the polygon area
    /// (holes subtracted). Near-zero means the triangulation covers the
    /// polygon; used by tests to validate output.
    static func deviation(data: [Double], holeIndices: [Int], dim: Int, triangles: [UInt32]) -> Double {
        let hasHoles = holeIndices.isEmpty == false
        let outerLen = hasHoles ? holeIndices[0] * dim : data.count

        var polygonArea = abs(signedArea(data: data, start: 0, end: outerLen, dim: dim))
        if hasHoles {
            for holeNumber in 0..<holeIndices.count {
                let start = holeIndices[holeNumber] * dim
                let end = holeNumber < holeIndices.count - 1 ? holeIndices[holeNumber + 1] * dim : data.count
                polygonArea -= abs(signedArea(data: data, start: start, end: end, dim: dim))
            }
        }

        var trianglesArea = 0.0
        for triangleStart in stride(from: 0, to: triangles.count, by: 3) {
            let a = Int(triangles[triangleStart]) * dim
            let b = Int(triangles[triangleStart + 1]) * dim
            let c = Int(triangles[triangleStart + 2]) * dim
            trianglesArea += abs(
                (data[a] - data[c]) * (data[b + 1] - data[a + 1]) -
                (data[a] - data[b]) * (data[c + 1] - data[a + 1]))
        }

        if polygonArea == 0 && trianglesArea == 0 {
            return 0
        }
        return abs((trianglesArea - polygonArea) / polygonArea)
    }

    fileprivate static func signedArea(data: [Double], start: Int, end: Int, dim: Int) -> Double {
        var sum = 0.0
        var j = end - dim
        var i = start
        while i < end {
            sum += (data[j] - data[i]) * (data[i + 1] + data[j + 1])
            j = i
            i += dim
        }
        return sum
    }
}

private final class EarcutCore {
    /// Ring/z-list node. Links are indices into `nodes`; `nilIndex` plays null.
    private struct Node {
        var x: Double
        var y: Double
        /// Output vertex index (already divided by `dim`).
        var i: Int32
        var prev: Int32
        var next: Int32
        var prevZ: Int32
        var nextZ: Int32
        /// z-order curve value; 0 doubles as "not yet computed" like in
        /// earcut.js (recomputing the legitimate 0 value is harmless).
        var z: Int32
        var steiner: Bool
    }

    private static let nilIndex: Int32 = -1

    private let data: [Double]
    private let dim: Int
    private var nodes: ContiguousArray<Node> = []
    private var triangles: [UInt32] = []
    private var minX = 0.0
    private var minY = 0.0
    private var invSize = 0.0

    init(data: [Double], dim: Int) {
        self.data = data
        self.dim = dim
    }

    func run(holeIndices: [Int]) -> [UInt32] {
        let hasHoles = holeIndices.isEmpty == false
        let outerLen = hasHoles ? holeIndices[0] * dim : data.count
        let vertexCount = data.count / dim
        // Ring nodes + two per hole bridge; splits during pass 2 can add more,
        // the pool just grows then.
        nodes.reserveCapacity(vertexCount + 2 * holeIndices.count)
        triangles.reserveCapacity(max(0, (vertexCount - 2) * 3))

        var outerNode = linkedList(start: 0, end: outerLen, clockwise: true)
        guard outerNode != Self.nilIndex,
              nodes[Int(outerNode)].next != nodes[Int(outerNode)].prev else {
            return []
        }

        if hasHoles {
            outerNode = eliminateHoles(holeIndices: holeIndices, outerNode: outerNode)
            guard outerNode != Self.nilIndex else { return [] }
        }

        // For non-trivial polygons a z-order curve hash accelerates the
        // point-in-ear tests; the bounding box intentionally covers the outer
        // ring only, exactly like the reference implementation.
        if data.count > 80 * dim {
            minX = data[0]
            minY = data[1]
            var maxX = minX
            var maxY = minY
            var i = dim
            while i < outerLen {
                let x = data[i]
                let y = data[i + 1]
                if x < minX { minX = x }
                if y < minY { minY = y }
                if x > maxX { maxX = x }
                if y > maxY { maxY = y }
                i += dim
            }
            invSize = max(maxX - minX, maxY - minY)
            invSize = invSize != 0 ? 32767 / invSize : 0
        }

        earcutLinked(ear: outerNode, pass: 0)
        return triangles
    }

    // MARK: - Linked list construction

    /// Creates a circular doubly linked list from polygon points in the
    /// specified winding order.
    private func linkedList(start: Int, end: Int, clockwise: Bool) -> Int32 {
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
    private func filterPoints(start: Int32, end providedEnd: Int32 = EarcutCore.nilIndex) -> Int32 {
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

    // MARK: - Ear clipping

    /// Main ear slicing loop which triangulates a polygon (given as a linked
    /// list).
    private func earcutLinked(ear startEar: Int32, pass: Int) {
        var ear = startEar
        guard ear != Self.nilIndex else { return }

        // Interlink polygon nodes in z-order.
        if pass == 0 && invSize != 0 {
            indexCurve(start: ear)
        }

        var stop = ear

        // Iterate through ears, slicing them one by one.
        while nodes[Int(ear)].prev != nodes[Int(ear)].next {
            let prev = nodes[Int(ear)].prev
            let next = nodes[Int(ear)].next

            if invSize != 0 ? isEarHashed(ear) : isEar(ear) {
                // Cut off the triangle.
                triangles.append(UInt32(nodes[Int(prev)].i))
                triangles.append(UInt32(nodes[Int(ear)].i))
                triangles.append(UInt32(nodes[Int(next)].i))

                removeNode(ear)

                // Skipping the next vertex leads to fewer sliver triangles.
                ear = nodes[Int(next)].next
                stop = ear
                continue
            }

            ear = next

            // The whole remaining polygon was scanned and no ear was found.
            if ear == stop {
                if pass == 0 {
                    // Try filtering points and slicing again.
                    earcutLinked(ear: filterPoints(start: ear), pass: 1)
                } else if pass == 1 {
                    // Try curing all small self-intersections locally.
                    let cured = cureLocalIntersections(start: filterPoints(start: ear))
                    earcutLinked(ear: cured, pass: 2)
                } else if pass == 2 {
                    // As a last resort, try splitting the remaining polygon
                    // into two.
                    splitEarcut(start: ear)
                }
                break
            }
        }
    }

    /// Whether a polygon node forms a valid ear with adjacent nodes.
    private func isEar(_ ear: Int32) -> Bool {
        let a = nodes[Int(ear)].prev
        let b = ear
        let c = nodes[Int(ear)].next

        if area(a, b, c) >= 0 { return false } // reflex, can't be an ear

        let ax = nodes[Int(a)].x, ay = nodes[Int(a)].y
        let bx = nodes[Int(b)].x, by = nodes[Int(b)].y
        let cx = nodes[Int(c)].x, cy = nodes[Int(c)].y

        // Triangle bbox.
        let x0 = min(ax, bx, cx), y0 = min(ay, by, cy)
        let x1 = max(ax, bx, cx), y1 = max(ay, by, cy)

        var p = nodes[Int(c)].next
        while p != a {
            let node = nodes[Int(p)]
            if node.x >= x0, node.x <= x1, node.y >= y0, node.y <= y1,
               pointInTriangle(ax, ay, bx, by, cx, cy, node.x, node.y),
               area(node.prev, p, node.next) >= 0 {
                return false
            }
            p = node.next
        }

        return true
    }

    private func isEarHashed(_ ear: Int32) -> Bool {
        let a = nodes[Int(ear)].prev
        let b = ear
        let c = nodes[Int(ear)].next

        if area(a, b, c) >= 0 { return false } // reflex, can't be an ear

        let ax = nodes[Int(a)].x, ay = nodes[Int(a)].y
        let bx = nodes[Int(b)].x, by = nodes[Int(b)].y
        let cx = nodes[Int(c)].x, cy = nodes[Int(c)].y

        // Triangle bbox.
        let x0 = min(ax, bx, cx), y0 = min(ay, by, cy)
        let x1 = max(ax, bx, cx), y1 = max(ay, by, cy)

        // z-order range of the current triangle bbox.
        let minZ = zOrder(x0, y0)
        let maxZ = zOrder(x1, y1)

        var p = nodes[Int(ear)].prevZ
        var n = nodes[Int(ear)].nextZ

        // Look for points inside the triangle in both directions.
        while p != Self.nilIndex, nodes[Int(p)].z >= minZ,
              n != Self.nilIndex, nodes[Int(n)].z <= maxZ {
            let pNode = nodes[Int(p)]
            if pNode.x >= x0, pNode.x <= x1, pNode.y >= y0, pNode.y <= y1, p != a, p != c,
               pointInTriangle(ax, ay, bx, by, cx, cy, pNode.x, pNode.y),
               area(pNode.prev, p, pNode.next) >= 0 {
                return false
            }
            p = pNode.prevZ

            let nNode = nodes[Int(n)]
            if nNode.x >= x0, nNode.x <= x1, nNode.y >= y0, nNode.y <= y1, n != a, n != c,
               pointInTriangle(ax, ay, bx, by, cx, cy, nNode.x, nNode.y),
               area(nNode.prev, n, nNode.next) >= 0 {
                return false
            }
            n = nNode.nextZ
        }

        // Look for remaining points in decreasing z-order.
        while p != Self.nilIndex, nodes[Int(p)].z >= minZ {
            let pNode = nodes[Int(p)]
            if pNode.x >= x0, pNode.x <= x1, pNode.y >= y0, pNode.y <= y1, p != a, p != c,
               pointInTriangle(ax, ay, bx, by, cx, cy, pNode.x, pNode.y),
               area(pNode.prev, p, pNode.next) >= 0 {
                return false
            }
            p = pNode.prevZ
        }

        // Look for remaining points in increasing z-order.
        while n != Self.nilIndex, nodes[Int(n)].z <= maxZ {
            let nNode = nodes[Int(n)]
            if nNode.x >= x0, nNode.x <= x1, nNode.y >= y0, nNode.y <= y1, n != a, n != c,
               pointInTriangle(ax, ay, bx, by, cx, cy, nNode.x, nNode.y),
               area(nNode.prev, n, nNode.next) >= 0 {
                return false
            }
            n = nNode.nextZ
        }

        return true
    }

    /// Goes through all polygon nodes and cures small local
    /// self-intersections.
    private func cureLocalIntersections(start providedStart: Int32) -> Int32 {
        var start = providedStart
        guard start != Self.nilIndex else { return start }
        var p = start
        repeat {
            let a = nodes[Int(p)].prev
            let pNext = nodes[Int(p)].next
            let b = nodes[Int(pNext)].next

            if equals(a, b) == false,
               intersects(a, p, pNext, b),
               locallyInside(a, b), locallyInside(b, a) {
                triangles.append(UInt32(nodes[Int(a)].i))
                triangles.append(UInt32(nodes[Int(p)].i))
                triangles.append(UInt32(nodes[Int(b)].i))

                // Remove the two involved nodes.
                removeNode(p)
                removeNode(pNext)

                p = b
                start = b
            }
            p = nodes[Int(p)].next
        } while p != start

        return filterPoints(start: p)
    }

    /// Tries splitting the polygon into two and triangulating them
    /// independently.
    private func splitEarcut(start: Int32) {
        // Look for a valid diagonal that divides the polygon into two.
        var a = start
        repeat {
            var b = nodes[Int(nodes[Int(a)].next)].next
            while b != nodes[Int(a)].prev {
                if nodes[Int(a)].i != nodes[Int(b)].i, isValidDiagonal(a, b) {
                    // Split the polygon in two by the diagonal.
                    var c = splitPolygon(a, b)

                    // Filter colinear points around the cuts.
                    let filteredA = filterPoints(start: a, end: nodes[Int(a)].next)
                    c = filterPoints(start: c, end: nodes[Int(c)].next)

                    // Run earcut on each half.
                    earcutLinked(ear: filteredA, pass: 0)
                    earcutLinked(ear: c, pass: 0)
                    return
                }
                b = nodes[Int(b)].next
            }
            a = nodes[Int(a)].next
        } while a != start
    }

    // MARK: - Holes

    /// Links every hole into the outer loop, producing a single-ring polygon
    /// without holes.
    private func eliminateHoles(holeIndices: [Int], outerNode providedOuterNode: Int32) -> Int32 {
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

    // MARK: - z-order index

    /// Interlinks polygon nodes in z-order.
    private func indexCurve(start: Int32) {
        var p = start
        repeat {
            if nodes[Int(p)].z == 0 {
                nodes[Int(p)].z = zOrder(nodes[Int(p)].x, nodes[Int(p)].y)
            }
            nodes[Int(p)].prevZ = nodes[Int(p)].prev
            nodes[Int(p)].nextZ = nodes[Int(p)].next
            p = nodes[Int(p)].next
        } while p != start

        let lastZ = nodes[Int(p)].prevZ
        nodes[Int(lastZ)].nextZ = Self.nilIndex
        nodes[Int(p)].prevZ = Self.nilIndex

        _ = sortLinked(list: p)
    }

    /// Simon Tatham's linked-list merge sort, over the z links.
    private func sortLinked(list providedList: Int32) -> Int32 {
        var list = providedList
        var inSize = 1

        var numMerges = 0
        repeat {
            var p = list
            list = Self.nilIndex
            var tail = Self.nilIndex
            numMerges = 0

            while p != Self.nilIndex {
                numMerges += 1
                var q = p
                var pSize = 0
                for _ in 0..<inSize {
                    pSize += 1
                    q = nodes[Int(q)].nextZ
                    if q == Self.nilIndex { break }
                }
                var qSize = inSize

                while pSize > 0 || (qSize > 0 && q != Self.nilIndex) {
                    let e: Int32
                    if pSize != 0,
                       qSize == 0 || q == Self.nilIndex || nodes[Int(p)].z <= nodes[Int(q)].z {
                        e = p
                        p = nodes[Int(p)].nextZ
                        pSize -= 1
                    } else {
                        e = q
                        q = nodes[Int(q)].nextZ
                        qSize -= 1
                    }

                    if tail != Self.nilIndex {
                        nodes[Int(tail)].nextZ = e
                    } else {
                        list = e
                    }

                    nodes[Int(e)].prevZ = tail
                    tail = e
                }

                p = q
            }

            nodes[Int(tail)].nextZ = Self.nilIndex
            inSize *= 2
        } while numMerges > 1

        return list
    }

    /// z-order of a point given coords and inverse of the longer side of the
    /// data bbox.
    private func zOrder(_ xCoordinate: Double, _ yCoordinate: Double) -> Int32 {
        // Coords are transformed into a non-negative 15-bit integer range.
        // Clamping (instead of the JS |0 wraparound) keeps points outside the
        // outer-ring bbox from trapping the Double -> Int32 conversion.
        var x = Int32(min(max((xCoordinate - minX) * invSize, 0), 32767))
        var y = Int32(min(max((yCoordinate - minY) * invSize, 0), 32767))

        x = (x | (x << 8)) & 0x00FF00FF
        x = (x | (x << 4)) & 0x0F0F0F0F
        x = (x | (x << 2)) & 0x33333333
        x = (x | (x << 1)) & 0x55555555

        y = (y | (y << 8)) & 0x00FF00FF
        y = (y | (y << 4)) & 0x0F0F0F0F
        y = (y | (y << 2)) & 0x33333333
        y = (y | (y << 1)) & 0x55555555

        return x | (y << 1)
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

    // MARK: - Geometry predicates

    private func pointInTriangle(_ ax: Double, _ ay: Double,
                                 _ bx: Double, _ by: Double,
                                 _ cx: Double, _ cy: Double,
                                 _ px: Double, _ py: Double) -> Bool {
        (cx - px) * (ay - py) >= (ax - px) * (cy - py)
            && (ax - px) * (by - py) >= (bx - px) * (ay - py)
            && (bx - px) * (cy - py) >= (cx - px) * (by - py)
    }

    /// Whether a diagonal between two polygon nodes is valid (lies in polygon
    /// interior).
    private func isValidDiagonal(_ a: Int32, _ b: Int32) -> Bool {
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
    private func area(_ p: Int32, _ q: Int32, _ r: Int32) -> Double {
        let pNode = nodes[Int(p)]
        let qNode = nodes[Int(q)]
        let rNode = nodes[Int(r)]
        return (qNode.y - pNode.y) * (rNode.x - qNode.x) - (qNode.x - pNode.x) * (rNode.y - qNode.y)
    }

    /// Whether two points are equal.
    private func equals(_ a: Int32, _ b: Int32) -> Bool {
        nodes[Int(a)].x == nodes[Int(b)].x && nodes[Int(a)].y == nodes[Int(b)].y
    }

    /// Whether two segments intersect.
    private func intersects(_ p1: Int32, _ q1: Int32, _ p2: Int32, _ q2: Int32) -> Bool {
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
    private func locallyInside(_ a: Int32, _ b: Int32) -> Bool {
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

    // MARK: - Node pool plumbing

    /// Links two polygon vertices with a bridge; if the vertices belong to the
    /// same ring, it splits the polygon into two; if one belongs to the outer
    /// ring and another to a hole, it merges them into a single ring.
    private func splitPolygon(_ a: Int32, _ b: Int32) -> Int32 {
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
    private func insertNode(i: Int32, x: Double, y: Double, last: Int32) -> Int32 {
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

    private func removeNode(_ p: Int32) {
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
