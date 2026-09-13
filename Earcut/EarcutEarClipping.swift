// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT
//
// Part of the mapbox/earcut port. The ISC notice heads EarcutCore.swift and
// is repeated in THIRD-PARTY-NOTICES.md at the repository root.

// The ear slicing loop itself: the ear test in both its plain and its
// z-order hashed form, and the fallbacks a stuck polygon falls through.
extension EarcutCore {
    /// Main ear slicing loop which triangulates a polygon (given as a linked
    /// list).
    func earcutLinked(ear startEar: Int32) {
        var ear = startEar
        guard ear != Self.nilIndex else { return }

        // Interlink polygon nodes in z-order.
        if invSize != 0 {
            indexCurve(start: ear)
        }

        var stop = ear
        var cured = false

        // Iterate through ears, slicing them one by one.
        while nodes[Int(ear)].prev != nodes[Int(ear)].next {
            let prev = nodes[Int(ear)].prev
            let next = nodes[Int(ear)].next

            if area(prev, ear, next) < 0, invSize != 0 ? isEarHashed(ear) : isEar(ear) {
                // Cut off the triangle.
                triangles.append(UInt32(nodes[Int(prev)].i))
                triangles.append(UInt32(nodes[Int(ear)].i))
                triangles.append(UInt32(nodes[Int(next)].i))

                removeNode(ear)
                ear = next
                stop = next
                continue
            }

            ear = next

            // The whole remaining polygon was scanned and no ear was found.
            if ear == stop {
                // Try filtering collinear/coincident points and slicing
                // again, and repeat as long as filtering actually removes
                // nodes, since each removal can expose new ears.
                filteredOut = false
                ear = filterPoints(start: ear)
                if filteredOut {
                    stop = ear
                    continue
                }

                // Filtering is exhausted: cure small local self-intersections
                // once, then retry.
                if cured == false {
                    ear = cureLocalIntersections(start: ear)
                    stop = ear
                    cured = true
                    continue
                }

                // As a last resort, try splitting the remaining polygon into
                // two.
                splitEarcut(start: ear)
                break
            }
        }
    }

    /// Whether a polygon node forms a valid ear with adjacent nodes. The
    /// reflex check (`area(a, b, c) >= 0`) is hoisted into `earcutLinked`.
    private func isEar(_ ear: Int32) -> Bool {
        let a = nodes[Int(ear)].prev
        let c = nodes[Int(ear)].next

        let ax = nodes[Int(a)].x, ay = nodes[Int(a)].y
        let bx = nodes[Int(ear)].x, by = nodes[Int(ear)].y
        let cx = nodes[Int(c)].x, cy = nodes[Int(c)].y

        // Triangle bbox.
        let x0 = min(ax, bx, cx), y0 = min(ay, by, cy)
        let x1 = max(ax, bx, cx), y1 = max(ay, by, cy)

        // Make sure we don't have other points inside the potential ear.
        var p = nodes[Int(c)].next
        while p != a {
            let node = nodes[Int(p)]
            if node.x >= x0, node.x <= x1, node.y >= y0, node.y <= y1,
               (ax == node.x && ay == node.y) == false,
               pointInTriangle(ax, ay, bx, by, cx, cy, node.x, node.y),
               area(node.prev, p, node.next) >= 0 {
                return false
            }
            p = node.next
        }

        return true
    }

    /// The ear test over the z-order neighbourhood. The reflex check is
    /// hoisted into `earcutLinked` like for `isEar`.
    private func isEarHashed(_ ear: Int32) -> Bool {
        let a = nodes[Int(ear)].prev
        let c = nodes[Int(ear)].next

        let ax = nodes[Int(a)].x, ay = nodes[Int(a)].y
        let bx = nodes[Int(ear)].x, by = nodes[Int(ear)].y
        let cx = nodes[Int(c)].x, cy = nodes[Int(c)].y

        // Triangle bbox.
        let x0 = min(ax, bx, cx), y0 = min(ay, by, cy)
        let x1 = max(ax, bx, cx), y1 = max(ay, by, cy)

        // z-order range of the current triangle bbox.
        let minZ = zOrder(x0, y0)
        let maxZ = zOrder(x1, y1)

        // Look for points inside the triangle in decreasing z-order.
        var p = nodes[Int(ear)].prevZ
        while p != Self.nilIndex, nodes[Int(p)].z >= minZ {
            let node = nodes[Int(p)]
            if node.x >= x0, node.x <= x1, node.y >= y0, node.y <= y1, p != c,
               (ax == node.x && ay == node.y) == false,
               pointInTriangle(ax, ay, bx, by, cx, cy, node.x, node.y),
               area(node.prev, p, node.next) >= 0 {
                return false
            }
            p = node.prevZ
        }

        // Look for points in increasing z-order.
        var n = nodes[Int(ear)].nextZ
        while n != Self.nilIndex, nodes[Int(n)].z <= maxZ {
            let node = nodes[Int(n)]
            if node.x >= x0, node.x <= x1, node.y >= y0, node.y <= y1, n != c,
               (ax == node.x && ay == node.y) == false,
               pointInTriangle(ax, ay, bx, by, cx, cy, node.x, node.y),
               area(node.prev, n, node.next) >= 0 {
                return false
            }
            n = node.nextZ
        }

        return true
    }

    /// Goes through all polygon nodes and cures small local
    /// self-intersections.
    private func cureLocalIntersections(start providedStart: Int32) -> Int32 {
        var start = providedStart
        var p = start
        var cured = false
        repeat {
            let a = nodes[Int(p)].prev
            let pNext = nodes[Int(p)].next
            let b = nodes[Int(pNext)].next

            if intersects(a, p, pNext, b, includeBoundary: false),
               locallyInside(a, b), locallyInside(b, a) {
                triangles.append(UInt32(nodes[Int(a)].i))
                triangles.append(UInt32(nodes[Int(p)].i))
                triangles.append(UInt32(nodes[Int(b)].i))

                // Remove the two involved nodes.
                removeNode(p)
                removeNode(pNext)

                p = b
                start = b
                cured = true
            }
            p = nodes[Int(p)].next
        } while p != start

        return cured ? filterPoints(start: p) : p
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
                    a = filterPoints(start: a, end: nodes[Int(a)].next)
                    c = filterPoints(start: c, end: nodes[Int(c)].next)

                    // Run earcut on each half.
                    earcutLinked(ear: a)
                    earcutLinked(ear: c)
                    return
                }
                b = nodes[Int(b)].next
            }
            a = nodes[Int(a)].next
        } while a != start
    }
}
