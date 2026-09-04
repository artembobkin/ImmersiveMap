// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT
//
// Part of the mapbox/earcut port; the ISC notice heads EarcutCore.swift and
// is repeated in THIRD-PARTY-NOTICES.md at the repository root.

// The ear slicing loop itself: the ear test in both its plain and its
// z-order hashed form, and the two fallbacks a stuck polygon falls through.
extension EarcutCore {
    /// Main ear slicing loop which triangulates a polygon (given as a linked
    /// list).
    func earcutLinked(ear startEar: Int32, pass: Int) {
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
}
