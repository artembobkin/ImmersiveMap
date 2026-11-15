// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Earcut
import Foundation
import simd

/// A zone's fill vertex: the position in its chunk's render units and the
/// colour. Mirrors `LayerFillVertex` in Layers.metal, 16 bytes.
struct LayerFillVertex: Equatable {
    var position: SIMD2<Float>
    var color: SIMD4<UInt8>
}

/// One segment of a line: its ends in its chunk's render units, the line's
/// width in points and its colour. The vertex stage draws the segment as
/// a shape of the screen, as wide as the line, with a round end where
/// `color.w` says so (`roundStart`, `roundEnd`): a line is always solid,
/// so the fourth byte of its colour is not an alpha. Two segments that
/// meet with round ends are joined by the disc those ends share. An
/// instance, not a vertex: every segment is the same ten corners
/// (`LayerPipeline.lineTemplateIndices`). Mirrors `LayerLineSegment` in
/// Layers.metal, 24 bytes.
struct LayerLineSegment: Equatable {
    static let roundStart: UInt8 = 1
    static let roundEnd: UInt8 = 2

    var start: SIMD2<Float>
    var end: SIMD2<Float>
    var widthPoints: Float
    var color: SIMD4<UInt8>
}

/// A disc on screen: a point of the layer, or a line of a single vertex,
/// which has no segment to round. Mirrors `LayerPointInstance` in Layers.metal, 24
/// bytes.
struct LayerPointInstance: Equatable {
    var position: SIMD2<Float>
    var radiusPoints: Float
    var strokeWidthPoints: Float
    var color: SIMD4<UInt8>
    var strokeColor: SIMD4<UInt8>
}

/// The shapes of a layer whose geometry lies in one tile of `chunkZoom`:
/// their positions are in that tile's render units (x east, y north, 0 to
/// 4096 across the tile, beyond it for a shape that reaches out of it),
/// which keeps them precise at every zoom, and they draw under the tile's
/// matrix, as a map tile does. The ranges are into the layer's buffers.
struct LayerMeshChunk: Equatable {
    let tile: Tile
    let fillIndexStart: Int
    let fillIndexCount: Int
    let lineStart: Int
    let lineCount: Int
    let joinStart: Int
    let joinCount: Int
    let pointStart: Int
    let pointCount: Int
    /// The box round every position of the chunk, in its render units. A
    /// frame leaves out a chunk whose box is outside the view
    /// (`LayerChunkCulling`).
    let boundsMinimum: SIMD2<Float>
    let boundsMaximum: SIMD2<Float>
    /// How far past its position a line or a point of the chunk reaches on
    /// screen, in points: the widest line's half width, the largest disc's
    /// radius with its ring.
    let maximumReachPoints: Float
}

/// A layer on the CPU, ready for its buffers (`LayerMeshStore`).
struct LayerMeshData {
    var fillVertices: [LayerFillVertex] = []
    var fillIndices: [UInt32] = []
    var lineSegments: [LayerLineSegment] = []
    /// The lines of a single vertex first, then the points.
    var discs: [LayerPointInstance] = []
    var chunks: [LayerMeshChunk] = []

    var isEmpty: Bool { chunks.isEmpty }
}

/// Turns a layer's shapes into its GPU form. Every coordinate goes to the
/// Web-Mercator world (x east and y south, 0 to 1 across the world), with
/// the longitudes of a ring or a line run on past ±180 rather than jumping
/// back, so a shape across the 180th meridian stays whole, and the
/// latitude kept within the Mercator range. A shape belongs to the chunk
/// of its bounds' centre. A zone is triangulated whole (earcut, holes
/// included), its triangles and every line's segments cut until no edge
/// is longer than `maximumEdgeLength`, so on the globe a zone and a line
/// follow the sphere instead of cutting through it. Pure: no Metal, no
/// state, testable alone.
enum LayerMeshBuilder {
    /// The tile zoom of the chunks.
    static let chunkZoom = 6
    /// The longest edge a triangle or a segment keeps, in world units:
    /// short enough that its chord under the sphere stays under a pixel at
    /// the globe's zooms, about 150 km.
    static let maximumEdgeLength = 1.0 / 256.0
    /// How many times a triangle may be split, so a degenerate one cannot
    /// run away: a zone over the whole world takes about 17 levels to
    /// bring every edge under `maximumEdgeLength`.
    static let maximumSplitDepth = 20

    /// The mesh of `layer` drawing `content`, the shapes of its source.
    static func build(layer: ImmersiveMapLayer, content: LayerSourceContent) -> LayerMeshData {
        var chunks: [Tile: ChunkBuilder] = [:]
        var order: [Tile] = []
        func chunk(_ tile: Tile) -> ChunkBuilder {
            if let existing = chunks[tile] { return existing }
            let builder = ChunkBuilder(tile: tile)
            chunks[tile] = builder
            order.append(tile)
            return builder
        }

        for polygon in content.polygons {
            let style = layer.style(of: polygon)
            var exterior = unwrappedWorld(polygon.exterior, reference: nil)
            guard exterior.count >= 3 else { continue }
            var holes = polygon.holes.map { unwrappedWorld($0, reference: exterior.first) }.filter { $0.count >= 3 }
            let shift = worldShift(of: exterior)
            exterior = exterior.map { $0 - SIMD2<Double>(shift, 0) }
            holes = holes.map { ring in ring.map { $0 - SIMD2<Double>(shift, 0) } }
            let builder = chunk(chunkTile(of: exterior))
            if style.fillColor.w > 0 {
                builder.appendFill(exterior: exterior, holes: holes, color: style.fillColor)
            }
            if style.strokeColor.w > 0, style.strokeWidthPoints > 0 {
                for ring in [exterior] + holes {
                    builder.appendLine(ring, closed: true, widthPoints: style.strokeWidthPoints, color: style.strokeColor)
                }
            }
        }

        for polyline in content.polylines {
            let style = layer.style(of: polyline)
            guard style.color.w > 0, style.widthPoints > 0 else { continue }
            var line = unwrappedWorld(polyline.coordinates, reference: nil)
            guard line.count >= 1 else { continue }
            let shift = worldShift(of: line)
            line = line.map { $0 - SIMD2<Double>(shift, 0) }
            chunk(chunkTile(of: line)).appendLine(line, closed: false, widthPoints: style.widthPoints, color: style.color)
        }

        for point in content.points {
            let style = layer.style(of: point)
            guard style.radiusPoints + style.strokeWidthPoints > 0,
                  style.color.w > 0 || style.strokeColor.w > 0 else { continue }
            var world = self.world(point.coordinate)
            world.x -= world.x.rounded(.down)
            chunk(chunkTile(of: [world])).appendPoint(world, style: style)
        }

        var data = LayerMeshData()
        // The joins of every chunk first, then the points: the lines'
        // joins draw with the lines, before the points.
        var pointsByChunk: [[LayerPointInstance]] = []
        var pendingChunks: [(builder: ChunkBuilder, fillStart: Int, fillCount: Int, lineStart: Int, lineCount: Int,
                             joinStart: Int, joinCount: Int)] = []
        for tile in order {
            guard let builder = chunks[tile] else { continue }
            let fillBase = UInt32(data.fillVertices.count)
            let fillStart = data.fillIndices.count
            data.fillVertices += builder.fillVertices
            data.fillIndices += builder.fillIndices.map { $0 + fillBase }
            let lineStart = data.lineSegments.count
            data.lineSegments += builder.lineSegments
            let joinStart = data.discs.count
            data.discs += builder.joins
            pendingChunks.append((builder, fillStart, builder.fillIndices.count, lineStart, builder.lineSegments.count,
                                  joinStart, builder.joins.count))
            pointsByChunk.append(builder.points)
        }
        for (pending, points) in zip(pendingChunks, pointsByChunk) {
            let pointStart = data.discs.count
            data.discs += points
            data.chunks.append(LayerMeshChunk(tile: pending.builder.tile,
                                              fillIndexStart: pending.fillStart,
                                              fillIndexCount: pending.fillCount,
                                              lineStart: pending.lineStart,
                                              lineCount: pending.lineCount,
                                              joinStart: pending.joinStart,
                                              joinCount: pending.joinCount,
                                              pointStart: pointStart,
                                              pointCount: points.count,
                                              boundsMinimum: pending.builder.boundsMinimum,
                                              boundsMaximum: pending.builder.boundsMaximum,
                                              maximumReachPoints: pending.builder.maximumReachPoints))
        }
        return data
    }

    // MARK: - The world

    /// A coordinate in the Mercator world, the longitude not wrapped.
    static func world(_ coordinate: GeoCoordinate) -> SIMD2<Double> {
        let maximumLatitude = ImmersiveMapProjection.maxMercatorLatitude * 180 / .pi
        let latitude = min(max(coordinate.latitude, -maximumLatitude), maximumLatitude) * .pi / 180
        let x = (coordinate.longitude + 180) / 360
        let y = (1 - log(tan(latitude) + 1 / cos(latitude)) / .pi) / 2
        return SIMD2<Double>(x, y)
    }

    /// A ring or a line in the world, each longitude run on from the one
    /// before it (from `reference` for the first), so it never jumps by
    /// more than half the world. A ring's repeated last coordinate is
    /// dropped.
    static func unwrappedWorld(_ coordinates: [GeoCoordinate], reference: SIMD2<Double>?) -> [SIMD2<Double>] {
        var points: [SIMD2<Double>] = []
        points.reserveCapacity(coordinates.count)
        var previous = reference
        for coordinate in coordinates {
            guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else { continue }
            var point = world(coordinate)
            if let previous {
                point.x += (previous.x - point.x).rounded()
            }
            if let last = points.last, simd_distance_squared(last, point) < 1e-24 {
                continue
            }
            points.append(point)
            previous = point
        }
        if points.count > 1, let first = points.first, let last = points.last, simd_distance_squared(first, last) < 1e-24 {
            points.removeLast()
        }
        return points
    }

    /// The whole worlds a shape is moved by so its bounds' centre lies in
    /// the first copy of the world.
    static func worldShift(of points: [SIMD2<Double>]) -> Double {
        guard let minimum = points.map(\.x).min(), let maximum = points.map(\.x).max() else { return 0 }
        return ((minimum + maximum) / 2).rounded(.down)
    }

    /// The chunk tile of a shape: the tile of `chunkZoom` its bounds'
    /// centre lies in.
    static func chunkTile(of points: [SIMD2<Double>]) -> Tile {
        var minimum = points[0]
        var maximum = points[0]
        for point in points {
            minimum = simd_min(minimum, point)
            maximum = simd_max(maximum, point)
        }
        let centre = (minimum + maximum) / 2
        let count = Double(1 << chunkZoom)
        let x = min(max(Int((centre.x * count).rounded(.down)), 0), (1 << chunkZoom) - 1)
        let y = min(max(Int((centre.y * count).rounded(.down)), 0), (1 << chunkZoom) - 1)
        return Tile(x: x, y: y, z: chunkZoom)
    }

    static func packedColor(_ color: SIMD4<Float>) -> SIMD4<UInt8> {
        let clamped = simd_clamp(color, SIMD4<Float>(repeating: 0), SIMD4<Float>(repeating: 1))
        return SIMD4<UInt8>((clamped * 255).rounded(.toNearestOrAwayFromZero))
    }

    // MARK: - A chunk

    final class ChunkBuilder {
        let tile: Tile
        var fillVertices: [LayerFillVertex] = []
        var fillIndices: [UInt32] = []
        var lineSegments: [LayerLineSegment] = []
        var joins: [LayerPointInstance] = []
        var points: [LayerPointInstance] = []
        /// The box round every position `local` has given out.
        private(set) var boundsMinimum = SIMD2<Float>(repeating: .infinity)
        private(set) var boundsMaximum = SIMD2<Float>(repeating: -.infinity)
        private(set) var maximumReachPoints: Float = 0
        private let tileOrigin: SIMD2<Double>
        private let unitsPerWorld: Double

        init(tile: Tile) {
            self.tile = tile
            let count = Double(1 << tile.z)
            tileOrigin = SIMD2<Double>(Double(tile.x), Double(tile.y)) / count
            unitsPerWorld = count * TileCoordinateSpace.tileExtentDouble
        }

        /// A world point in the chunk's render units, y north.
        func local(_ world: SIMD2<Double>) -> SIMD2<Float> {
            let tileSpace = (world - tileOrigin) * unitsPerWorld
            let position = SIMD2<Float>(Float(tileSpace.x), Float(TileCoordinateSpace.tileExtentDouble - tileSpace.y))
            boundsMinimum = simd_min(boundsMinimum, position)
            boundsMaximum = simd_max(boundsMaximum, position)
            return position
        }

        func appendFill(exterior: [SIMD2<Double>], holes: [[SIMD2<Double>]], color: SIMD4<Float>) {
            var data: [Double] = []
            var holeIndices: [Int] = []
            var rings: [SIMD2<Double>] = []
            for ring in [exterior] + holes {
                if rings.isEmpty == false {
                    holeIndices.append(rings.count)
                }
                for point in ring {
                    data.append(point.x)
                    data.append(point.y)
                    rings.append(point)
                }
            }
            let triangles = Earcut.tessellate(data: data, holeIndices: holeIndices)
            guard triangles.isEmpty == false else { return }
            let packed = LayerMeshBuilder.packedColor(color)
            var cache: [SIMD2<Double>: UInt32] = [:]
            func index(of point: SIMD2<Double>) -> UInt32 {
                if let existing = cache[point] { return existing }
                let index = UInt32(fillVertices.count)
                fillVertices.append(LayerFillVertex(position: local(point), color: packed))
                cache[point] = index
                return index
            }
            var start = 0
            while start + 2 < triangles.count {
                let a = rings[Int(triangles[start])]
                let b = rings[Int(triangles[start + 1])]
                let c = rings[Int(triangles[start + 2])]
                LayerMeshBuilder.forEachSplitTriangle(a, b, c, depth: 0) { p, q, r in
                    // Counter-clockwise in render space (y north), the
                    // front face the sphere's back-face culling keeps: in
                    // the world y runs south, so a triangle clockwise
                    // there is counter-clockwise on the map.
                    let cross = (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
                    guard abs(cross) > 0 else { return }
                    let (second, third) = cross < 0 ? (q, r) : (r, q)
                    fillIndices.append(index(of: p))
                    fillIndices.append(index(of: second))
                    fillIndices.append(index(of: third))
                }
                start += 3
            }
        }

        /// A line of the layer, always solid: its colour's alpha only
        /// says whether it draws (`ImmersiveMapPolylineStyle.color`). A
        /// line is drawn in parts that overlap, its segments at their
        /// round ends, so a translucent one would darken itself at every
        /// vertex.
        func appendLine(_ points: [SIMD2<Double>], closed: Bool, widthPoints: Float, color: SIMD4<Float>) {
            let packed = LayerMeshBuilder.packedColor(SIMD4<Float>(color.x, color.y, color.z, 1))
            maximumReachPoints = max(maximumReachPoints, widthPoints / 2)
            guard points.count >= 2 else {
                // A line of one vertex is a dot: there is no segment to
                // round, so it is a disc.
                for point in points {
                    joins.append(LayerPointInstance(position: local(point),
                                                    radiusPoints: widthPoints / 2,
                                                    strokeWidthPoints: 0,
                                                    color: packed,
                                                    strokeColor: packed))
                }
                return
            }
            var segments = Array(zip(points, points.dropFirst()))
            if closed, let first = points.first, let last = points.last {
                segments.append((last, first))
            }
            for (start, end) in segments {
                let pieces = max(1, Int((simd_distance(start, end) / LayerMeshBuilder.maximumEdgeLength).rounded(.up)))
                var previous = start
                for piece in 1 ... pieces {
                    let next = piece == pieces ? end : start + (end - start) * (Double(piece) / Double(pieces))
                    // Round at every vertex the shape states, which joins
                    // the segments and ends an open line, and flat where a
                    // long segment was only cut to follow the sphere.
                    appendSegment(local(previous), local(next),
                                  roundStart: piece == 1, roundEnd: piece == pieces,
                                  widthPoints: widthPoints, color: packed)
                    previous = next
                }
            }
        }

        private func appendSegment(_ start: SIMD2<Float>,
                                   _ end: SIMD2<Float>,
                                   roundStart: Bool,
                                   roundEnd: Bool,
                                   widthPoints: Float,
                                   color: SIMD4<UInt8>) {
            let rounding = (roundStart ? LayerLineSegment.roundStart : 0) | (roundEnd ? LayerLineSegment.roundEnd : 0)
            lineSegments.append(LayerLineSegment(start: start,
                                                 end: end,
                                                 widthPoints: widthPoints,
                                                 color: SIMD4(color.x, color.y, color.z, rounding)))
        }

        func appendPoint(_ world: SIMD2<Double>, style: ImmersiveMapPointStyle) {
            maximumReachPoints = max(maximumReachPoints, style.radiusPoints + style.strokeWidthPoints)
            points.append(LayerPointInstance(position: local(world),
                                             radiusPoints: style.radiusPoints,
                                             strokeWidthPoints: style.strokeWidthPoints,
                                             color: LayerMeshBuilder.packedColor(style.color),
                                             strokeColor: LayerMeshBuilder.packedColor(style.strokeColor)))
        }
    }

    /// A triangle cut at the midpoint of its longest edge until no edge is
    /// longer than `maximumEdgeLength`.
    static func forEachSplitTriangle(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>,
                                     depth: Int,
                                     _ body: (SIMD2<Double>, SIMD2<Double>, SIMD2<Double>) -> Void) {
        let ab = simd_distance_squared(a, b)
        let bc = simd_distance_squared(b, c)
        let ca = simd_distance_squared(c, a)
        let longest = max(ab, bc, ca)
        guard longest > maximumEdgeLength * maximumEdgeLength, depth < maximumSplitDepth else {
            body(a, b, c)
            return
        }
        if longest == ab {
            let m = (a + b) / 2
            forEachSplitTriangle(a, m, c, depth: depth + 1, body)
            forEachSplitTriangle(m, b, c, depth: depth + 1, body)
        } else if longest == bc {
            let m = (b + c) / 2
            forEachSplitTriangle(a, b, m, depth: depth + 1, body)
            forEachSplitTriangle(a, m, c, depth: depth + 1, body)
        } else {
            let m = (c + a) / 2
            forEachSplitTriangle(a, b, m, depth: depth + 1, body)
            forEachSplitTriangle(m, b, c, depth: depth + 1, body)
        }
    }
}
