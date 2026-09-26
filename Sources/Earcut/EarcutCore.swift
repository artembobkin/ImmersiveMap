// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT
//
// Port of mapbox/earcut (https://github.com/mapbox/earcut) v3.2.3, ISC license:
//   Copyright (c) 2016, Mapbox
//   Permission to use, copy, modify, and/or distribute this software for any
//   purpose with or without fee is hereby granted, provided that the above
//   copyright notice and this permission notice appear in all copies.
//
//   THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
//   WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
//   MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
//   SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
//   WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION
//   OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN
//   CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//
// The port keeps earcut.js function structure and naming for auditability, but
// stores nodes as plain structs in one contiguous pool linked by Int32 indices.
// The previous dependency (SwiftEarcut) modeled nodes as classes with `weak`
// back references, which made every linked-list hop in the ear-clipping loops
// pay ARC plus weak-table traffic. On an ocean polygon with dozens of island
// holes that was ~48 ms per tile. The flat pool triangulates the same input in
// well under a millisecond.
//
// What is ported is the triangulator: `earcut` and `deviation`. The optional
// `refine` post-pass of v3.2 (Lawson flips toward a constrained Delaunay
// triangulation) is not, because nothing in the engine reads triangle shape:
// fills are flat-shaded and the globe subdivides them on a grid regardless.

// One triangulation of one polygon: the node pool, the state every phase of
// the algorithm reads, and `run`, which is the algorithm top to bottom. The
// phases themselves are extensions in the sibling files. Members are internal
// only so those files can reach them. Nothing outside this target sees the
// type at all.
final class EarcutCore {
    /// Ring/z-list node. Links are indices into `nodes`, and `nilIndex` plays null.
    struct Node {
        var x: Double
        var y: Double
        /// Output vertex index (already divided by `dim`).
        var i: Int32
        var prev: Int32
        var next: Int32
        var prevZ: Int32
        var nextZ: Int32
        /// z-order curve value once `indexCurve` has run. While
        /// `eliminateHoles` merges holes it holds the index of the block
        /// that owns the node in the hole-bridge index instead, which is why
        /// `indexCurve` always recomputes it.
        var z: Int32
        /// A single-vertex hole (a Steiner point), which `filterPoints`
        /// must keep even though it carries no shape.
        var steiner: Bool
    }

    static let nilIndex: Int32 = -1

    let data: [Double]
    let dim: Int
    var nodes: ContiguousArray<Node> = []
    var triangles: [UInt32] = []
    var minX = 0.0
    var minY = 0.0
    var invSize = 0.0

    /// Set by `filterPoints` whenever it removes at least one node. The stall
    /// handler in `earcutLinked` reads it to decide whether another clipping
    /// pass is worth attempting before the costlier stages.
    var filteredOut = false

    // The hole-bridge block index (EarcutHoleBridgeIndex.swift): one bounding
    // box per run of ring edges, so the ray scans of `findHoleBridge` skip
    // whole runs instead of walking the merged ring.
    var blockBBox: [Double] = []
    var blockHead: [Int32] = []
    var blockStop: [Int32] = []
    /// True only while `eliminateHoles` merges holes, so `removeNode` keeps
    /// the block boxes covering the edges `filterPoints` heals.
    var indexActive = false

    // Scratch for the z-order sort (EarcutZOrder.swift): the node list being
    // sorted, its ping-pong buffer, the z values read from contiguous memory
    // during the radix passes, and the 256-entry digit histogram. All empty
    // until a ring is long enough to need them, so a small polygon pays for
    // none of it.
    var sortArr: [Int32] = []
    var sortBuf: [Int32] = []
    var zArr: [UInt32] = []
    var zBuf: [UInt32] = []
    var counts: [Int] = []

    init(data: [Double], dim: Int) {
        self.data = data
        self.dim = dim
    }

    func run(holeIndices: [Int]) -> [UInt32] {
        let hasHoles = holeIndices.isEmpty == false
        let outerLen = hasHoles ? holeIndices[0] * dim : data.count
        let vertexCount = data.count / dim
        // Ring nodes + two per hole bridge. Splits during the last-resort
        // pass can add more, and the pool just grows then.
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
        // point-in-ear tests. The bounding box intentionally covers the outer
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

        earcutLinked(ear: outerNode)
        return triangles
    }
}
