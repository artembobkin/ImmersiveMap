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
/// The fills go in as their triangles, three-point rings of the style's
/// paint in ascending style order, so a later style covers an earlier one
/// as the layered draw would have painted it. A paint is opaque and names
/// its style in its red byte: the flattener composites paints by alpha,
/// and a transparent one would drop out. The mesh comes back as one
/// polygon per style, the vertex carrying the style index as before, so
/// the shader, the fades and the runs (`GroundStyleRunScanner`) are the
/// layered tile's. The fills a style draws among the ground lines
/// (`ParsedPolygon.isLineRibbon`) are not flattened: they keep their place
/// in the ribbons class.
enum GroundFlattening {
    static let tileExtent = Double(TileCoordinateSpace.tileExtentDouble)

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
                let vertices = polygon.vertices
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
        }
        guard paintStyles.isEmpty == false else { return kept }

        var options = FlattenOptions()
        options.minX = 0
        options.minY = 0
        options.maxX = tileExtent
        options.maxY = tileExtent
        options.columns = max(1, grid)
        options.rows = max(1, grid)
        let mesh = Flattener.flatten(input, options: options)

        // One polygon per style, the mesh's vertices renumbered per style.
        // The mesh shares a vertex within one paint only, so a vertex has
        // one style, and the triangles come out with a positive signed
        // area, the counter-clockwise winding of render space.
        var byStyle: [UInt8: (vertices: [SIMD2<Int16>], indices: [UInt32], remap: [UInt32: UInt32])] = [:]
        var triangle = 0
        while triangle + 2 < mesh.indices.count {
            let first = mesh.indices[triangle]
            let style = FlatColor(packed: mesh.vertices[Int(first)].color).r
            var entry = byStyle[style] ?? ([], [], [:])
            for corner in 0 ..< 3 {
                let source = mesh.indices[triangle + corner]
                if let local = entry.remap[source] {
                    entry.indices.append(local)
                } else {
                    let vertex = mesh.vertices[Int(source)]
                    let local = UInt32(entry.vertices.count)
                    entry.vertices.append(SIMD2<Int16>(Int16(vertex.x.rounded()), Int16(vertex.y.rounded())))
                    entry.remap[source] = local
                    entry.indices.append(local)
                }
            }
            byStyle[style] = entry
            triangle += 3
        }
        var result = kept
        for (style, entry) in byStyle where entry.indices.isEmpty == false {
            var polygon = ParsedPolygon(vertices: entry.vertices, indices: entry.indices)
            polygon.windCounterClockwise()
            result[style, default: []].append(polygon)
        }
        return result
    }
}
