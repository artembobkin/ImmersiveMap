// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import TileFlattening

/// Flattens the ground fills of a tile into one layer of triangles that do
/// not overlap (`TileFlattening`), for the tiles of the zooms the camera
/// blows up (`TileParseOptions.flattensGround(tileZoom:)`).
///
/// A layered tile orders its fills by a rank in the vertex depth, which
/// the near plane's cut moves on a triangle blown up to many screens
/// (Tile.metal): the fills then swap from frame to frame at a street tilt.
/// A flattened tile has nothing to order: every pixel of its ground is
/// one fill, so its fills draw at one depth, and no triangle of it crosses
/// a cell of a `grid` by `grid` grid, which keeps every edge short against
/// the near distance and makes the mesh ready for a heightmap.
///
/// The fills go in as rings of the style's paint in ascending style
/// order, so a later style covers an earlier one as the layered draw
/// would have painted it: a fill the parse kept as its outline
/// (`ParsedPolygon.outlineStarts`, the bulk of the ground) as its rings,
/// and a tessellated fill (the background quad, a building's footprint)
/// as three-point rings of its triangles. A paint is opaque and names
/// its style in its red byte: the flattener composites paints by alpha,
/// and a transparent one would drop out. The mesh comes back as one
/// polygon per style, the vertex carrying the style index as before, so
/// the shader, the fades and the runs (`GroundStyleRunScanner`) are the
/// layered tile's. The fills a style draws among the ground lines
/// (`ParsedPolygon.isLineRibbon`) are not flattened: they keep their place
/// in the ribbons class.
enum GroundFlattening {
    static let tileExtent = Double(TileCoordinateSpace.tileExtentDouble)
    /// The fewest strips the flattener sweeps a tile in, whatever the grid:
    /// the sweep's cost grows faster than the strip's share of the fills,
    /// and a coarse tile on a coarse grid (zoom 7 on 16 cells, with its
    /// two hundred thousand triangles of landuse) swept in 16 strips takes
    /// over twice as long as in 64. The extra strips cut a few more
    /// triangles along their walls and never a cell: the grid's rows and
    /// columns are among them.
    static let minimumSweepColumns = 64

    /// A fill's rings into the flattener's input: an outline's rings as
    /// they are, a tessellated fill's triangles one ring each.
    static func addRings(of polygon: ParsedPolygon, paint: Int, to input: inout FlattenInput) {
        let vertices = polygon.vertices
        if polygon.isOutline {
            let starts = polygon.outlineStarts
            for ring in 0 ..< starts.count {
                let end = ring + 1 < starts.count ? Int(starts[ring + 1]) : vertices.count
                input.beginRing(paint: paint)
                for index in Int(starts[ring]) ..< end {
                    let vertex = vertices[index]
                    input.addPoint(x: Double(vertex.x), y: Double(vertex.y))
                }
                input.endRing()
            }
            return
        }
        var index = 0
        while index + 2 < polygon.indices.count {
            input.beginRing(paint: paint)
            for corner in 0 ..< 3 {
                let vertex = vertices[Int(polygon.indices[index + corner])]
                input.addPoint(x: Double(vertex.x), y: Double(vertex.y))
            }
            input.endRing()
            index += 3
        }
    }

    static func flatten(polygonByStyle: [UInt8: [ParsedPolygon]], grid: Int) -> [UInt8: [ParsedPolygon]] {
        var input = FlattenInput()
        var paintStyles: [UInt8] = []
        var kept: [UInt8: [ParsedPolygon]] = [:]
        for style in polygonByStyle.keys.sorted() {
            var fills: [ParsedPolygon] = []
            for polygon in polygonByStyle[style] ?? [] {
                if polygon.isLineRibbon {
                    kept[style, default: []].append(polygon)
                } else {
                    fills.append(polygon)
                }
            }
            guard fills.isEmpty == false else { continue }
            let paint = input.addPaint(FlatColor(r: style, g: 0, b: 0, a: 255))
            paintStyles.append(style)
            for polygon in fills {
                Self.addRings(of: polygon, paint: paint, to: &input)
            }
        }
        guard paintStyles.isEmpty == false else { return kept }

        var options = FlattenOptions()
        options.minX = 0
        options.minY = 0
        options.maxX = tileExtent
        options.maxY = tileExtent
        options.columns = max(max(1, grid), Self.minimumSweepColumns)
        options.rows = max(1, grid)
        let mesh = Flattener.flatten(input, options: options)

        // One polygon per style, the mesh's vertices renumbered per style,
        // the coordinates as the flattener left them: unrounded, so the
        // triangles stay watertight. The mesh shares a
        // vertex within one paint only, so a vertex has one style and one
        // place in its style's polygon: one renumbering table over the
        // mesh's vertices, filled on first use, and per-style streams that
        // grow in place.
        var localIndex = [UInt32](repeating: .max, count: mesh.vertices.count)
        var verticesByStyle = [[SIMD2<Float>]](repeating: [], count: paintStyles.count)
        var indicesByStyle = [[UInt32]](repeating: [], count: paintStyles.count)
        var slotOfStyle = [Int](repeating: -1, count: 256)
        for (slot, style) in paintStyles.enumerated() {
            slotOfStyle[Int(style)] = slot
        }
        var triangle = 0
        while triangle + 2 < mesh.indices.count {
            let first = mesh.indices[triangle]
            let slot = slotOfStyle[Int(FlatColor(packed: mesh.vertices[Int(first)].color).r)]
            guard slot >= 0 else {
                triangle += 3
                continue
            }
            for corner in 0 ..< 3 {
                let source = Int(mesh.indices[triangle + corner])
                var local = localIndex[source]
                if local == .max {
                    let vertex = mesh.vertices[source]
                    local = UInt32(verticesByStyle[slot].count)
                    verticesByStyle[slot].append(SIMD2<Float>(vertex.x, vertex.y))
                    localIndex[source] = local
                }
                indicesByStyle[slot].append(local)
            }
            triangle += 3
        }
        // The flattener winds a triangle by the structure of its strip, not
        // by the sign of its area, and keeps the triangles without area
        // that close a T-junction. It works in double and hands back
        // floats, so such a sliver can round into a small negative area,
        // which the winding check in `TileUnificationStage.appendPolygon`
        // rejects. Flipping it covers the same ground (none), so the
        // winding is settled on the floats last, as for the other fills.
        var result = kept
        for (slot, style) in paintStyles.enumerated() where indicesByStyle[slot].isEmpty == false {
            var polygon = ParsedPolygon(vertices: verticesByStyle[slot], indices: indicesByStyle[slot])
            polygon.windCounterClockwise()
            result[style, default: []].append(polygon)
        }
        return result
    }
}
