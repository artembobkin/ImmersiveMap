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

// One triangulation of one polygon: the node pool, the state every phase of
// the algorithm reads, and `run`, which is the algorithm top to bottom. The
// phases themselves are extensions in the sibling files. Members are internal
// only so those files can reach them; nothing outside this target sees the
// type at all.
final class EarcutCore {
    /// Ring/z-list node. Links are indices into `nodes`; `nilIndex` plays null.
    struct Node {
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

    static let nilIndex: Int32 = -1

    let data: [Double]
    let dim: Int
    var nodes: ContiguousArray<Node> = []
    var triangles: [UInt32] = []
    var minX = 0.0
    var minY = 0.0
    var invSize = 0.0

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
}
