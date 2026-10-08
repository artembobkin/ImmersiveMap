// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import TileFlattening

/// Brute-force reference: what color should be visible at a point, straight from the input rings.
struct Reference {
    let input: FlattenInput

    /// Winding number of every paint at the point.
    func windings(x: Double, y: Double) -> [Int] {
        var result = [Int](repeating: 0, count: input.paints.count)
        for ring in input.rings {
            let start = Int(ring.start) * 2
            let count = Int(ring.count)
            var ax = input.coords[start + 2 * (count - 1)]
            var ay = input.coords[start + 2 * (count - 1) + 1]
            for k in 0..<count {
                let bx = input.coords[start + 2 * k]
                let by = input.coords[start + 2 * k + 1]
                if (ay <= y) != (by <= y) {
                    let xCross = ax + (y - ay) * (bx - ax) / (by - ay)
                    if xCross < x { result[Int(ring.paint)] += by > ay ? 1 : -1 }
                }
                ax = bx
                ay = by
            }
        }
        return result
    }

    /// The topmost covering paint. Only valid when all paints are opaque.
    func color(x: Double, y: Double) -> UInt32 {
        let winding = windings(x: x, y: y)
        for paint in stride(from: input.paints.count - 1, through: 0, by: -1) where winding[paint] != 0 {
            return input.paints[paint].packed
        }
        return 0
    }

    /// Distance from the point to the nearest input edge.
    func distanceToEdges(x: Double, y: Double) -> Double {
        var best = Double.infinity
        for ring in input.rings {
            let start = Int(ring.start) * 2
            let count = Int(ring.count)
            var ax = input.coords[start + 2 * (count - 1)]
            var ay = input.coords[start + 2 * (count - 1) + 1]
            for k in 0..<count {
                let bx = input.coords[start + 2 * k]
                let by = input.coords[start + 2 * k + 1]
                let dx = bx - ax, dy = by - ay
                let lengthSquared = dx * dx + dy * dy
                var t = lengthSquared > 0 ? ((x - ax) * dx + (y - ay) * dy) / lengthSquared : 0
                t = min(max(t, 0), 1)
                let px = ax + t * dx - x, py = ay + t * dy - y
                best = min(best, (px * px + py * py).squareRoot())
                ax = bx
                ay = by
            }
        }
        return best
    }
}

/// Finds the triangle under a point with a uniform grid over the mesh.
struct MeshLocator {
    let mesh: FlatMesh
    let minX: Double, minY: Double, cell: Double
    let size: Int
    var buckets: [[Int32]]

    init(mesh: FlatMesh, minX: Double, minY: Double, maxX: Double, maxY: Double, size: Int = 64) {
        self.mesh = mesh
        self.minX = minX
        self.minY = minY
        self.size = size
        cell = max(maxX - minX, maxY - minY) / Double(size)
        buckets = [[Int32]](repeating: [], count: size * size)
        for t in 0..<mesh.triangleCount {
            let a = mesh.vertices[Int(mesh.indices[3 * t])]
            let b = mesh.vertices[Int(mesh.indices[3 * t + 1])]
            let c = mesh.vertices[Int(mesh.indices[3 * t + 2])]
            let x0 = index(Double(min(a.x, b.x, c.x)) - minX), x1 = index(Double(max(a.x, b.x, c.x)) - minX)
            let y0 = index(Double(min(a.y, b.y, c.y)) - minY), y1 = index(Double(max(a.y, b.y, c.y)) - minY)
            for gy in y0...y1 { for gx in x0...x1 { buckets[gy * size + gx].append(Int32(t)) } }
        }
    }

    private func index(_ v: Double) -> Int { min(max(Int(v / cell), 0), size - 1) }

    /// Colors of all triangles that contain the point.
    func colors(x: Double, y: Double) -> [UInt32] {
        var result: [UInt32] = []
        for t in buckets[index(y - minY) * size + index(x - minX)] {
            let a = mesh.vertices[Int(mesh.indices[3 * Int(t)])]
            let b = mesh.vertices[Int(mesh.indices[3 * Int(t) + 1])]
            let c = mesh.vertices[Int(mesh.indices[3 * Int(t) + 2])]
            func side(_ p: FlatVertex, _ q: FlatVertex) -> Double {
                (Double(q.x) - Double(p.x)) * (y - Double(p.y)) - (Double(q.y) - Double(p.y)) * (x - Double(p.x))
            }
            if side(a, b) >= 0 && side(b, c) >= 0 && side(c, a) >= 0 { result.append(a.color) }
        }
        return result
    }
}

struct MeshReport {
    var area = 0.0
    /// Edges inside the bounds that are not matched by the same edge of a neighbour triangle.
    var openEdges = 0
    var mixedColorTriangles = 0
    /// Triangles that reach over a grid line of `columns` x `rows`.
    var gridCrossingTriangles = 0
    /// Triangles that are clearly clockwise. Slivers along a straight edge do not count.
    var flippedTriangles = 0
}

func inspect(_ mesh: FlatMesh, options: FlattenOptions) -> MeshReport {
    struct Edge: Hashable {
        var ax: UInt32, ay: UInt32, bx: UInt32, by: UInt32
    }
    var report = MeshReport()
    let extent = max(options.maxX - options.minX, options.maxY - options.minY)
    var edges: [Edge: Int] = [:]
    edges.reserveCapacity(mesh.indices.count)
    for t in 0..<mesh.triangleCount {
        let v = (0..<3).map { mesh.vertices[Int(mesh.indices[3 * t + $0])] }
        if v[0].color != v[1].color || v[0].color != v[2].color { report.mixedColorTriangles += 1 }
        let area = 0.5 * ((Double(v[1].x) - Double(v[0].x)) * (Double(v[2].y) - Double(v[0].y))
            - (Double(v[1].y) - Double(v[0].y)) * (Double(v[2].x) - Double(v[0].x)))
        if area < -1e-7 * extent * extent { report.flippedTriangles += 1 }
        report.area += area
        let cellWidth = (options.maxX - options.minX) / Double(max(1, options.columns))
        let cellHeight = (options.maxY - options.minY) / Double(max(1, options.rows))
        let xs = v.map { (Double($0.x) - options.minX) / cellWidth }
        let ys = v.map { (Double($0.y) - options.minY) / cellHeight }
        if (xs.max()! - 1e-4).rounded(.down) > (xs.min()! + 1e-4).rounded(.down)
            || (ys.max()! - 1e-4).rounded(.down) > (ys.min()! + 1e-4).rounded(.down) {
            report.gridCrossingTriangles += 1
        }
        for k in 0..<3 {
            let p = v[k], q = v[(k + 1) % 3]
            // Adding 0 turns -0 into +0, so equal positions have equal bits.
            let forward = Edge(ax: (p.x + 0).bitPattern, ay: (p.y + 0).bitPattern, bx: (q.x + 0).bitPattern, by: (q.y + 0).bitPattern)
            let backward = Edge(ax: forward.bx, ay: forward.by, bx: forward.ax, by: forward.ay)
            // Two distinct points can round to the same Float position. Such an edge has no length.
            if forward == backward { continue }
            if let count = edges[backward], count > 0 {
                edges[backward] = count - 1
            } else {
                edges[forward, default: 0] += 1
            }
        }
    }
    let minX = Float(options.minX), maxX = Float(options.maxX)
    let minY = Float(options.minY), maxY = Float(options.maxY)
    for (edge, count) in edges where count > 0 {
        let ax = Float(bitPattern: edge.ax), ay = Float(bitPattern: edge.ay)
        let bx = Float(bitPattern: edge.bx), by = Float(bitPattern: edge.by)
        let onBorder = (ax == bx && (ax == minX || ax == maxX)) || (ay == by && (ay == minY || ay == maxY))
        if !onBorder { report.openEdges += count }
    }
    return report
}

/// A small deterministic generator, so that failures can be reproduced from the seed.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed &* 0x9E3779B97F4A7C15 &+ 0x1234567
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
