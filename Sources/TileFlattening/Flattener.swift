// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Dispatch

public struct FlattenOptions: Sendable {
    /// The area to produce, in the units of the input. Everything outside is clipped away.
    public var minX: Double = 0
    public var minY: Double = 0
    public var maxX: Double = 4096
    public var maxY: Double = 4096

    /// Number of vertical strips. Each strip is swept independently (and in parallel), and no
    /// triangle crosses a strip border. More strips make the sweep faster up to a point, and add
    /// triangles along the borders.
    public var columns: Int = 16

    /// Number of horizontal bands. No triangle crosses a band border. 1 means no bands.
    ///
    /// For a mesh that will be displaced by a heightmap, set `columns` and `rows` to the grid size
    /// of the terrain: every triangle then lies inside one grid cell.
    public var rows: Int = 1

    /// Sweep the strips on all cores.
    public var parallel: Bool = true

    public init() {}
}

/// Wall-clock time of each stage, in seconds.
public struct FlattenTimings: Sendable {
    public var binning: Double = 0
    public var sweep: Double = 0
    public var triangulation: Double = 0
    public var merge: Double = 0

    public init() {}

    public var total: Double { binning + sweep + triangulation + merge }
}

public enum Flattener {
    /// Flattens stacked, overlapping painted rings into one layer of triangles that do not overlap.
    ///
    /// Inside the bounds the mesh has no T-junctions: two triangles that touch share whole edges,
    /// so the mesh stays closed when its vertices are moved, for example by a heightmap.
    public static func flatten(_ input: FlattenInput, options: FlattenOptions = FlattenOptions()) -> FlatMesh {
        var timings = FlattenTimings()
        return flatten(input, options: options, timings: &timings)
    }

    public static func flatten(
        _ input: FlattenInput,
        options: FlattenOptions,
        timings: inout FlattenTimings
    ) -> FlatMesh {
        let clock = ContinuousClock()
        var mark = clock.now
        func lap() -> Double {
            let now = clock.now
            let duration = now - mark
            mark = now
            return Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
        }

        let columns = max(1, options.columns)
        let rows = max(1, options.rows)
        guard options.maxX > options.minX, options.maxY > options.minY, !input.paints.isEmpty else {
            return FlatMesh()
        }

        var walls = [Double](repeating: 0, count: columns + 1)
        for t in 0...columns {
            walls[t] = options.minX + (options.maxX - options.minX) * Double(t) / Double(columns)
        }
        walls[columns] = options.maxX
        var rowYs: [Double] = []
        if rows > 1 {
            for r in 1..<rows {
                rowYs.append(options.minY + (options.maxY - options.minY) * Double(r) / Double(rows))
            }
        }

        let binned = bin(input, walls: walls, minY: options.minY, maxY: options.maxY)
        let strips = (0..<columns).map { t in
            Strip(sweep: Sweep(
                pieces: binned.pieces[t], wallEvents: binned.wallEvents[t],
                wallL: walls[t], wallR: walls[t + 1],
                minY: options.minY, maxY: options.maxY, rowYs: rowYs, paints: input.paints
            ))
        }
        timings.binning = lap()

        forEachStrip(columns, parallel: options.parallel) { strips[$0].sweep.run() }
        timings.sweep = lap()

        // Both sides of a wall must agree on the vertices that lie on it.
        var wallMarks = [[Double]](repeating: [], count: columns + 1)
        for t in 0...columns {
            let fromRight = t < columns ? strips[t].sweep.leftMarks : []
            let fromLeft = t > 0 ? strips[t - 1].sweep.rightMarks : []
            wallMarks[t] = mergeAscending(fromLeft, fromRight)
        }
        let stripWalls = walls
        let stripWallMarks = wallMarks
        forEachStrip(columns, parallel: options.parallel) { t in
            let strip = strips[t]
            for poly in strip.sweep.polys {
                strip.triangulator.triangulate(
                    poly, data: strip.sweep.polyData,
                    wallL: stripWalls[t], wallR: stripWalls[t + 1],
                    leftWallMarks: stripWallMarks[t], rightWallMarks: stripWallMarks[t + 1]
                )
            }
        }
        timings.triangulation = lap()

        var vertexCount = 0
        var indexCount = 0
        for strip in strips {
            vertexCount += strip.triangulator.vertices.count
            indexCount += strip.triangulator.indices.count
        }
        let vertices = [FlatVertex](unsafeUninitializedCapacity: vertexCount) { buffer, count in
            var offset = 0
            for strip in strips {
                let source = strip.triangulator.vertices
                source.withUnsafeBufferPointer { src in
                    guard let address = src.baseAddress else { return }
                    (buffer.baseAddress! + offset).initialize(from: address, count: src.count)
                }
                offset += source.count
            }
            count = vertexCount
        }
        let indices = [UInt32](unsafeUninitializedCapacity: indexCount) { buffer, count in
            var offset = 0
            var base: UInt32 = 0
            for strip in strips {
                let source = strip.triangulator.indices
                for k in 0..<source.count { buffer[offset + k] = source[k] &+ base }
                offset += source.count
                base += UInt32(strip.triangulator.vertices.count)
            }
            count = indexCount
        }
        timings.merge = lap()
        return FlatMesh(vertices: vertices, indices: indices)
    }

    /// The working state of one strip. Each strip is only touched by one thread at a time.
    private final class Strip: @unchecked Sendable {
        var sweep: Sweep
        var triangulator = MonotoneTriangulator()

        init(sweep: Sweep) {
            self.sweep = sweep
        }
    }

    private static func forEachStrip(_ count: Int, parallel: Bool, _ body: @Sendable (Int) -> Void) {
        if parallel && count > 1 {
            DispatchQueue.concurrentPerform(iterations: count, execute: body)
        } else {
            for t in 0..<count { body(t) }
        }
    }

    private static func mergeAscending(_ a: [Double], _ b: [Double]) -> [Double] {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        var result: [Double] = []
        result.reserveCapacity(a.count + b.count)
        var i = 0
        var j = 0
        while i < a.count || j < b.count {
            let value: Double
            if j >= b.count || (i < a.count && a[i] <= b[j]) {
                value = a[i]
                i += 1
            } else {
                value = b[j]
                j += 1
            }
            if result.last != value { result.append(value) }
        }
        return result
    }

    // MARK: Binning

    private struct Binned {
        var pieces: [[EdgePiece]]
        var wallEvents: [[WallEvent]]
    }

    /// Distributes the edges of all rings over the strips.
    ///
    /// A strip only stores the edge parts inside it. Geometry to the left of a strip still decides
    /// what is inside and outside in the strip. That is carried by wall events: where a ring
    /// crosses the left wall of a strip, the winding number on the wall changes for everything
    /// below the crossing. Geometry to the right of a strip has no effect on it.
    private static func bin(_ input: FlattenInput, walls: [Double], minY: Double, maxY: Double) -> Binned {
        let columns = walls.count - 1
        let minX = walls[0]
        let inverseWidth = Double(columns) / (walls[columns] - minX)
        var pieces = [[EdgePiece]](repeating: [], count: columns)
        var wallEvents = [[WallEvent]](repeating: [], count: columns)
        let estimate = input.pointCount / columns + 16
        for t in 0..<columns { pieces[t].reserveCapacity(estimate) }

        // -1 is left of the bounds, `columns` is right of them (including the right border itself).
        @inline(__always) func stripIndex(_ x: Double) -> Int {
            let guess = ((x - minX) * inverseWidth).rounded(.down)
            var index = guess < -1 ? -1 : (guess > Double(columns) ? columns : Int(guess))
            while index >= 0 && x < walls[index] { index -= 1 }
            while index < columns && x >= walls[index + 1] { index += 1 }
            return index
        }

        @inline(__always) func addPiece(_ strip: Int, _ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ dxdy: Double, _ paint: UInt16) {
            if y0 == y1 { return }
            var piece = y0 < y1
                ? EdgePiece(xTop: x0, yTop: y0, xBot: x1, yBot: y1, dxdy: dxdy, paint: paint, dir: 1)
                : EdgePiece(xTop: x1, yTop: y1, xBot: x0, yBot: y0, dxdy: dxdy, paint: paint, dir: -1)
            if piece.yBot <= minY || piece.yTop >= maxY { return }
            let lo = walls[strip]
            let hi = walls[strip + 1]
            if piece.yTop < minY {
                piece.xTop = min(max(piece.xTop + (minY - piece.yTop) * dxdy, lo), hi)
                piece.yTop = minY
            }
            if piece.yBot > maxY {
                piece.xBot = min(max(piece.xTop + (maxY - piece.yTop) * dxdy, lo), hi)
                piece.yBot = maxY
            }
            pieces[strip].append(piece)
        }

        input.coords.withUnsafeBufferPointer { coords in
            for ring in input.rings {
                let start = Int(ring.start) * 2
                let count = Int(ring.count)
                let paint = ring.paint
                var ax = coords[start + 2 * (count - 1)]
                var ay = coords[start + 2 * (count - 1) + 1]
                var sa = stripIndex(ax)
                for k in 0..<count {
                    let bx = coords[start + 2 * k]
                    let by = coords[start + 2 * k + 1]
                    let sb = stripIndex(bx)
                    if sa == sb {
                        if sa >= 0 && sa < columns && ay != by {
                            addPiece(sa, ax, ay, bx, by, (bx - ax) / (by - ay), paint)
                        }
                    } else {
                        let dydx = (by - ay) / (bx - ax)
                        let dxdy = (bx - ax) / (by - ay)
                        let yLo = min(ay, by)
                        let yHi = max(ay, by)
                        var px = ax
                        var py = ay
                        if sa < sb {
                            // Moving right through the walls sa+1...sb.
                            var strip = sa
                            for t in (sa + 1)...sb {
                                let wx = walls[t]
                                let wy = wx == bx ? by : min(max(ay + (wx - ax) * dydx, yLo), yHi)
                                if strip >= 0 { addPiece(strip, px, py, wx, wy, dxdy, paint) }
                                if t < columns { wallEvents[t].append(WallEvent(y: wy, paint: paint, delta: -1)) }
                                px = wx
                                py = wy
                                strip = t
                            }
                            if sb < columns { addPiece(sb, px, py, bx, by, dxdy, paint) }
                        } else {
                            // Moving left through the walls sa...sb+1.
                            var strip = sa
                            for t in stride(from: sa, to: sb, by: -1) {
                                let wx = walls[t]
                                let wy = wx == ax ? ay : min(max(ay + (wx - ax) * dydx, yLo), yHi)
                                if strip < columns { addPiece(strip, px, py, wx, wy, dxdy, paint) }
                                if t < columns { wallEvents[t].append(WallEvent(y: wy, paint: paint, delta: 1)) }
                                px = wx
                                py = wy
                                strip = t - 1
                            }
                            if sb >= 0 { addPiece(sb, px, py, bx, by, dxdy, paint) }
                        }
                    }
                    ax = bx
                    ay = by
                    sa = sb
                }
            }
        }
        return Binned(pieces: pieces, wallEvents: wallEvents)
    }
}
