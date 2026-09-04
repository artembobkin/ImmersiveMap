// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT
//
// Part of the mapbox/earcut port; the ISC notice heads EarcutCore.swift and
// is repeated in THIRD-PARTY-NOTICES.md at the repository root.

// The z-order (Morton) curve over the ring, which is what makes the ear
// test on a large polygon a local scan instead of a full ring walk.
extension EarcutCore {
    /// Interlinks polygon nodes in z-order.
    func indexCurve(start: Int32) {
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
    func zOrder(_ xCoordinate: Double, _ yCoordinate: Double) -> Int32 {
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
}
