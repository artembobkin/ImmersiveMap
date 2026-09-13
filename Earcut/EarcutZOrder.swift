// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT
//
// Part of the mapbox/earcut port. The ISC notice heads EarcutCore.swift and
// is repeated in THIRD-PARTY-NOTICES.md at the repository root.

// The z-order (Morton) curve over the ring, which is what makes the ear
// test on a large polygon a local scan instead of a full ring walk.
extension EarcutCore {
    /// Interlinks polygon nodes in z-order: collects them into an array,
    /// sorts by z, relinks.
    func indexCurve(start: Int32) {
        sortArr.removeAll(keepingCapacity: true)
        var p = start
        repeat {
            // Always (re)compute: z may still hold a block index left over
            // from eliminateHoles.
            nodes[Int(p)].z = zOrder(nodes[Int(p)].x, nodes[Int(p)].y)
            sortArr.append(p)
            p = nodes[Int(p)].next
        } while p != start

        sortNodes()

        var prev = Self.nilIndex
        for node in sortArr {
            nodes[Int(node)].prevZ = prev
            if prev != Self.nilIndex {
                nodes[Int(prev)].nextZ = node
            }
            prev = node
        }
        nodes[Int(prev)].nextZ = Self.nilIndex
    }

    /// Sorts `sortArr` by z in place: insertion sort for a short list
    /// (cheaper than the histogram setup), else LSD radix in four 8-bit
    /// passes (covering z's 30 bits). Both are stable, so nodes of equal z
    /// keep ring order, the order the reference implementation produces.
    private func sortNodes() {
        let n = sortArr.count
        if n <= 32 {
            var i = 1
            while i < n {
                let node = sortArr[i]
                let z = nodes[Int(node)].z
                var j = i - 1
                while j >= 0, nodes[Int(sortArr[j])].z > z {
                    sortArr[j + 1] = sortArr[j]
                    j -= 1
                }
                sortArr[j + 1] = node
                i += 1
            }
            return
        }

        if zArr.count < n {
            zArr = [UInt32](repeating: 0, count: n)
            zBuf = [UInt32](repeating: 0, count: n)
            sortBuf = [Int32](repeating: 0, count: n)
        }
        if counts.isEmpty {
            counts = [Int](repeating: 0, count: 256)
        }
        for i in 0..<n {
            zArr[i] = UInt32(nodes[Int(sortArr[i])].z)
        }

        // An even pass count lands the sorted result back in sortArr.
        Self.radixPass(n: n, src: sortArr, srcZ: zArr, dst: &sortBuf, dstZ: &zBuf, counts: &counts, shift: 0)
        Self.radixPass(n: n, src: sortBuf, srcZ: zBuf, dst: &sortArr, dstZ: &zArr, counts: &counts, shift: 8)
        Self.radixPass(n: n, src: sortArr, srcZ: zArr, dst: &sortBuf, dstZ: &zBuf, counts: &counts, shift: 16)
        Self.radixPass(n: n, src: sortBuf, srcZ: zBuf, dst: &sortArr, dstZ: &zArr, counts: &counts, shift: 24)
    }

    /// One LSD radix pass: stably scatters the first n nodes (and their z)
    /// from src to dst, bucketed by the 8-bit digit of z at the given shift.
    private static func radixPass(n: Int,
                                  src: [Int32], srcZ: [UInt32],
                                  dst: inout [Int32], dstZ: inout [UInt32],
                                  counts: inout [Int],
                                  shift: UInt32) {
        for b in 0..<256 { counts[b] = 0 }
        for i in 0..<n {
            counts[Int((srcZ[i] >> shift) & 0xFF)] += 1
        }
        // Turn per-bucket counts into start offsets (prefix sum).
        var sum = 0
        for b in 0..<256 {
            let c = counts[b]
            counts[b] = sum
            sum += c
        }
        for i in 0..<n {
            let z = srcZ[i]
            let bucket = Int((z >> shift) & 0xFF)
            let pos = counts[bucket]
            counts[bucket] = pos + 1
            dst[pos] = src[i]
            dstZ[pos] = z
        }
    }

    /// z-order of a point given coords and inverse of the longer side of
    /// the data bbox.
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
