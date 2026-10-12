// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// Triangulates the monotone polygons produced by `Sweep`.
///
/// The polygons of one color share their vertices: a position is emitted once per color, and a
/// polygon that touches it refers to that vertex.
struct MonotoneTriangulator {
    private struct ChainVertex {
        var x: Double
        var y: Double
        var index: UInt32
        var onLeft: Bool
    }

    /// Twice the area below which three points count as collinear.
    static let collinearTolerance = 1e-6
    static let coincidentDistanceSquared = 1e-12

    /// A position with its color, the identity of a vertex: the regions of one color share the
    /// vertices on their common edges.
    private struct VertexKey: Hashable {
        var x: UInt32
        var y: UInt32
        var color: UInt32
    }

    var vertices: [FlatVertex] = []
    var indices: [UInt32] = []
    private var vertexIndex: [VertexKey: UInt32] = [:]

    private var left: [ChainVertex] = []
    private var right: [ChainVertex] = []
    private var order: [ChainVertex] = []
    private var stack: [ChainVertex] = []

    /// - Parameters:
    ///   - leftWallMarks: heights of all vertices on the left wall of the strip, from both sides.
    ///   - rightWallMarks: the same for the right wall.
    mutating func triangulate(
        _ poly: PolyHeader,
        data: [Double],
        wallL: Double,
        wallR: Double,
        leftWallMarks: [Double],
        rightWallMarks: [Double]
    ) {
        let offset = Int(poly.offset)
        let topCount = Int(poly.topCount)
        let bottomCount = Int(poly.bottomCount)
        let bottomStart = offset + topCount
        let leftStart = bottomStart + bottomCount
        let rightStart = leftStart + Int(poly.leftCount) * 3

        // Both chains run from the top-left point to the bottom-right point. The top side belongs
        // to the right chain and the bottom side to the left chain, which keeps both chains
        // ordered by (y, x).
        left.removeAll(keepingCapacity: true)
        right.removeAll(keepingCapacity: true)
        var created = 0

        func emit(_ x: Double, _ y: Double) -> UInt32 {
            // Adding 0 turns -0 into +0, so equal positions have equal bits.
            let fx = Float(x) + 0
            let fy = Float(y) + 0
            let key = VertexKey(x: fx.bitPattern, y: fy.bitPattern, color: poly.color)
            if let index = vertexIndex[key] { return index }
            let index = UInt32(vertices.count)
            vertices.append(FlatVertex(x: fx, y: fy, color: poly.color))
            vertexIndex[key] = index
            created += 1
            return index
        }

        let first = ChainVertex(x: data[offset], y: poly.yTop, index: emit(data[offset], poly.yTop), onLeft: true)
        left.append(first)
        right.append(first)
        if topCount > 1 {
            for k in IndexRange(1, topCount) {
                let x = data[offset + k]
                right.append(ChainVertex(x: x, y: poly.yTop, index: emit(x, poly.yTop), onLeft: false))
            }
        }

        // A stretch of a side along a strip wall gets the wall's vertices, strictly between its ends.
        func appendWallMarks(_ marks: [Double], wallX: Double, above: Double, below: Double, onLeft: Bool) {
            var k = lowerBound(marks, above: above)
            while k < marks.count && marks[k] < below {
                let vertex = ChainVertex(x: wallX, y: marks[k], index: emit(wallX, marks[k]), onLeft: onLeft)
                if onLeft { left.append(vertex) } else { right.append(vertex) }
                k += 1
            }
        }

        let rightCount = Int(poly.rightCount)
        var rightOnWall = poly.flags & PolyHeader.rightOnWall != 0
        var above = poly.yTop
        for k in IndexRange(0, rightCount) {
            let x = data[rightStart + 3 * k]
            let y = data[rightStart + 3 * k + 1]
            if rightOnWall { appendWallMarks(rightWallMarks, wallX: wallR, above: above, below: y, onLeft: false) }
            right.append(ChainVertex(x: x, y: y, index: emit(x, y), onLeft: false))
            rightOnWall = data[rightStart + 3 * k + 2] != 0
            above = y
        }
        if rightOnWall { appendWallMarks(rightWallMarks, wallX: wallR, above: above, below: poly.yBot, onLeft: false) }

        let leftCount = Int(poly.leftCount)
        var leftOnWall = poly.flags & PolyHeader.leftOnWall != 0
        above = poly.yTop
        for k in IndexRange(0, leftCount) {
            let x = data[leftStart + 3 * k]
            let y = data[leftStart + 3 * k + 1]
            if leftOnWall { appendWallMarks(leftWallMarks, wallX: wallL, above: above, below: y, onLeft: true) }
            left.append(ChainVertex(x: x, y: y, index: emit(x, y), onLeft: true))
            leftOnWall = data[leftStart + 3 * k + 2] != 0
            above = y
        }
        if leftOnWall { appendWallMarks(leftWallMarks, wallX: wallL, above: above, below: poly.yBot, onLeft: true) }

        for k in IndexRange(0, bottomCount) {
            let x = data[bottomStart + k]
            left.append(ChainVertex(x: x, y: poly.yBot, index: emit(x, poly.yBot), onLeft: true))
        }
        let last = left[left.count - 1]
        right.append(last)

        let count = left.count + right.count - 2
        if count < 3 {
            for _ in IndexRange(0, created) {
                let vertex = vertices.removeLast()
                vertexIndex.removeValue(forKey: VertexKey(x: vertex.x.bitPattern, y: vertex.y.bitPattern, color: vertex.color))
            }
            return
        }

        // A trapezoid without extra points is by far the most common shape.
        if count == 4 && topCount == 2 && bottomCount == 2 {
            // left: top-left, bottom-left, bottom-right. Right: top-left, top-right, bottom-right.
            addTriangle(left[0], right[1], left[2], reversed: false)
            addTriangle(left[0], left[2], left[1], reversed: false)
            return
        }

        // Merge both chains into one sequence ordered by (y, x).
        order.removeAll(keepingCapacity: true)
        order.append(first)
        var l = 1
        var r = 1
        let leftEnd = left.count - 1
        let rightEnd = right.count - 1
        while l < leftEnd || r < rightEnd {
            let takeLeft: Bool
            if r >= rightEnd {
                takeLeft = true
            } else if l >= leftEnd {
                takeLeft = false
            } else {
                let a = left[l], b = right[r]
                takeLeft = a.y < b.y || (a.y == b.y && a.x <= b.x)
            }
            if takeLeft {
                order.append(left[l])
                l += 1
            } else {
                order.append(right[r])
                r += 1
            }
        }
        order.append(last)

        stack.removeAll(keepingCapacity: true)
        stack.append(order[0])
        stack.append(order[1])
        if count > 3 {
            for k in IndexRange(2, count - 1) {
                let u = order[k]
                if u.onLeft != stack[stack.count - 1].onLeft {
                    let stackOnLeft = stack[stack.count - 1].onLeft
                    for s in IndexRange(0, stack.count - 1) { addTriangle(u, stack[s], stack[s + 1], reversed: stackOnLeft) }
                    let top = stack[stack.count - 1]
                    stack.removeAll(keepingCapacity: true)
                    stack.append(top)
                    stack.append(u)
                } else {
                    var lastPopped = stack.removeLast()
                    while let s = stack.last {
                        // The diagonal from u to s is inside when the corner at lastPopped is convex.
                        // A straight corner is left on the stack: the opposite chain connects to it
                        // later, which avoids a triangle without area.
                        let ex = lastPopped.x - s.x
                        let ey = lastPopped.y - s.y
                        let cross = ex * (u.y - lastPopped.y) - ey * (u.x - lastPopped.x)
                        // Two chain points that nearly coincide give a corner without a direction.
                        // Such a pair is removed with an empty triangle, so that it cannot hide a
                        // convex corner further up the chain.
                        let coincident = ex * ex + ey * ey < MonotoneTriangulator.coincidentDistanceSquared
                        if coincident || (u.onLeft ? cross < -MonotoneTriangulator.collinearTolerance : cross > MonotoneTriangulator.collinearTolerance) {
                            addTriangle(u, lastPopped, s, reversed: !u.onLeft)
                            lastPopped = s
                            stack.removeLast()
                        } else {
                            break
                        }
                    }
                    stack.append(lastPopped)
                    stack.append(u)
                }
            }
        }
        let u = order[count - 1]
        let stackOnLeft = stack[stack.count - 1].onLeft
        for s in IndexRange(0, stack.count - 1) { addTriangle(u, stack[s], stack[s + 1], reversed: stackOnLeft) }
    }

    /// The order comes from the structure of the polygon, not from the sign of the area: a
    /// triangle without area (three points on one straight edge) still has to face the same way
    /// as its neighbours, and it must not be dropped, or a T-junction would take its place.
    @inline(__always)
    private mutating func addTriangle(_ a: ChainVertex, _ b: ChainVertex, _ c: ChainVertex, reversed: Bool) {
        indices.append(a.index)
        indices.append(reversed ? c.index : b.index)
        indices.append(reversed ? b.index : c.index)
    }

    /// Index of the first element greater than `value` in an ascending array.
    private func lowerBound(_ array: [Double], above value: Double) -> Int {
        var lo = 0
        var hi = array.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if array[mid] <= value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
