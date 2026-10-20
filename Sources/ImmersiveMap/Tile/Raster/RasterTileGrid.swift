// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

/// The surface a raster tile is drawn on: a square grid over the tile's
/// extent, in tile-local units (0 to 4096, y up, the parser's render
/// space), counter-clockwise like every tile triangle. One grid per cell
/// count serves every tile: the draw places it by the tile's matrix on the
/// plane and by the tile's uv on the sphere, and the texture coordinate is
/// the vertex position itself.
///
/// A grid, not a quad, on both surfaces. On the sphere the cells bend the
/// tile around the globe as the subdivided geometry of a vector tile does
/// (`GroundGeometrySubdivider`), and on the plane they are where the
/// ground relief lifts the ground.
final class RasterTileGrid {
    struct Mesh {
        let vertices: MTLBuffer
        let indices: MTLBuffer
        let indexCount: Int
        /// 16-bit indices up to 255 cells a side, 32-bit past it.
        let indexType: MTLIndexType
    }

    /// The cells a side of the plane's grid and of the sphere's deep
    /// tiles: enough for a heightmap to shape a tile.
    static let minimumCells = 16
    /// The most cells a side: the flattening grid's ceiling
    /// (`GroundFlatteningSettings`), so the raster ground and the
    /// placement marks lie on the vector ground's lines at every zoom. A
    /// side of 257 vertices is past 16-bit indices, so such a grid takes
    /// 32-bit ones.
    static let maximumCells = 256
    /// The most cells a side 16-bit indices reach: a side of 256 vertices.
    static let maximumCellsWith16BitIndices = 255

    /// The cells a side of a tile of zoom `zoom`: the vector ground's split
    /// where the sphere needs one, so the raster tile bends as its
    /// geometry would, and `minimumCells` where it does not.
    static func cells(forTileZoom zoom: Int) -> Int {
        guard let step = GroundGeometrySubdivider.step(forTileZoom: zoom) else { return minimumCells }
        return max(minimumCells, 4096 / step)
    }

    /// The cells a side of a raster tile's grid on the relief: the zoom's
    /// flattening grid (`gridCells`), but never finer than the terrain
    /// under the tile has heights a side, as a vertex between two heights
    /// shows nothing new, nor than a cell to two texels of the tile's
    /// raster of `rasterSize`, the detail the ring was given. A far ring
    /// that reads a coarse terrain map (`FlatRingRule.terrainZoomDrop`) takes a grid
    /// of a few dozen cells instead of the flattening's hundreds. The
    /// raster tile's draw and its placement's stencil mark take the same,
    /// so the mark lies where the ground does.
    static func reliefCells(gridCells: Int, relief: GroundRelief, rasterSize: Int) -> Int {
        let terrainTexels = Int((Float(relief.terrain.size) * relief.scale).rounded(.down))
        return max(1, min(gridCells, terrainTexels, rasterSize / 2))
    }

    /// The raster size each source of a frame's placements draws its ground
    /// at (`RasterTileRenderSubsystem`): the largest of its raster
    /// placements, and none for a source drawn as geometry anywhere, which
    /// covers its raster slots with its geometry.
    static func rasterSizesBySource(_ placements: [PlaceTile]) -> [Tile: Int] {
        let vectorTiles = Set(placements.filter { $0.rules.raster == nil }.map(\.metalTile.tile))
        var sizes: [Tile: Int] = [:]
        for placement in placements {
            guard let raster = placement.rules.raster, vectorTiles.contains(placement.metalTile.tile) == false else { continue }
            sizes[placement.metalTile.tile] = max(sizes[placement.metalTile.tile] ?? 0, raster.size)
        }
        return sizes
    }

    private let device: MTLDevice
    private var meshesByCells: [Int: Mesh] = [:]

    init(device: MTLDevice) {
        self.device = device
    }

    /// The grid of a tile of zoom `zoom`, built the first time it is asked
    /// for, of at least `cells` cells a side: on the relief, the zoom's
    /// flattening grid, so the raster ground is as fine as the vector
    /// ground beside it. Main thread only, as the draw is.
    func mesh(forTileZoom zoom: Int, atLeast cells: Int = 0) -> Mesh? {
        mesh(cells: max(Self.cells(forTileZoom: zoom), cells))
    }

    /// The grid of exactly `cells` cells a side (1 to `maximumCells`),
    /// whatever the zoom: a part of a source's grid, drawn on the source's
    /// own lines (`PlacementGroundSquare.cells(ofSource:sourceZoom:squareZoom:)`).
    func mesh(cells: Int) -> Mesh? {
        let cells = min(max(cells, 1), Self.maximumCells)
        if let mesh = meshesByCells[cells] {
            return mesh
        }
        let mesh: Mesh?
        if cells <= Self.maximumCellsWith16BitIndices {
            mesh = makeMesh(geometry: Self.geometry(cells: cells, index: UInt16.self), indexType: .uint16)
        } else {
            mesh = makeMesh(geometry: Self.geometry(cells: cells, index: UInt32.self), indexType: .uint32)
        }
        meshesByCells[cells] = mesh
        return mesh
    }

    private func makeMesh<Index: FixedWidthInteger>(geometry: (vertices: [SIMD2<Float>], indices: [Index]),
                                                    indexType: MTLIndexType) -> Mesh? {
        guard let vertices = device.makeBuffer(bytes: geometry.vertices,
                                               length: geometry.vertices.count * MemoryLayout<SIMD2<Float>>.stride),
              let indices = device.makeBuffer(bytes: geometry.indices,
                                              length: geometry.indices.count * MemoryLayout<Index>.stride) else {
            return nil
        }
        let cells = Int(Double(geometry.vertices.count).squareRoot().rounded()) - 1
        vertices.label = "RasterTileGrid.vertices.\(cells)"
        indices.label = "RasterTileGrid.indices.\(cells)"
        return Mesh(vertices: vertices, indices: indices, indexCount: geometry.indices.count, indexType: indexType)
    }

    /// The vertices row by row from the tile's south edge, and two
    /// counter-clockwise triangles per cell, with 16-bit indices.
    static func geometry(cells: Int) -> (vertices: [SIMD2<Float>], indices: [UInt16]) {
        geometry(cells: cells, index: UInt16.self)
    }

    static func geometry<Index: FixedWidthInteger>(cells: Int, index _: Index.Type) -> (vertices: [SIMD2<Float>], indices: [Index]) {
        let side = cells + 1
        var vertices: [SIMD2<Float>] = []
        vertices.reserveCapacity(side * side)
        for row in 0 ... cells {
            for column in 0 ... cells {
                vertices.append(SIMD2<Float>(Float(column) / Float(cells) * 4096,
                                             Float(row) / Float(cells) * 4096))
            }
        }
        var indices: [Index] = []
        indices.reserveCapacity(cells * cells * 6)
        for row in 0 ..< cells {
            for column in 0 ..< cells {
                let southWest = Index(row * side + column)
                let southEast = southWest + 1
                let northWest = southWest + Index(side)
                let northEast = northWest + 1
                indices.append(contentsOf: [southWest, southEast, northEast, southWest, northEast, northWest])
            }
        }
        return (vertices, indices)
    }
}
