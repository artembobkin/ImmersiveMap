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
/// (`GroundGeometrySubdivider`), and on the plane they are where a
/// heightmap will lift the ground.
final class RasterTileGrid {
    struct Mesh {
        let vertices: MTLBuffer
        let indices: MTLBuffer
        let indexCount: Int
    }

    /// The cells a side of the plane's grid and of the sphere's deep
    /// tiles: enough for a heightmap to shape a tile.
    static let minimumCells = 16

    /// The cells a side of a tile of zoom `zoom`: the vector ground's split
    /// where the sphere needs one, so the raster tile bends as its
    /// geometry would, and `minimumCells` where it does not.
    static func cells(forTileZoom zoom: Int) -> Int {
        guard let step = GroundGeometrySubdivider.step(forTileZoom: zoom) else { return minimumCells }
        return max(minimumCells, 4096 / step)
    }

    private let device: MTLDevice
    private var meshesByCells: [Int: Mesh] = [:]

    init(device: MTLDevice) {
        self.device = device
    }

    /// The grid of a tile of zoom `zoom`, built the first time it is asked
    /// for. Main thread only, as the draw is.
    func mesh(forTileZoom zoom: Int) -> Mesh? {
        let cells = Self.cells(forTileZoom: zoom)
        if let mesh = meshesByCells[cells] {
            return mesh
        }
        let geometry = Self.geometry(cells: cells)
        guard let vertices = device.makeBuffer(bytes: geometry.vertices,
                                               length: geometry.vertices.count * MemoryLayout<SIMD2<Float>>.stride),
              let indices = device.makeBuffer(bytes: geometry.indices,
                                              length: geometry.indices.count * MemoryLayout<UInt16>.stride) else {
            return nil
        }
        vertices.label = "RasterTileGrid.vertices.\(cells)"
        indices.label = "RasterTileGrid.indices.\(cells)"
        let mesh = Mesh(vertices: vertices, indices: indices, indexCount: geometry.indices.count)
        meshesByCells[cells] = mesh
        return mesh
    }

    /// The vertices row by row from the tile's south edge, and two
    /// counter-clockwise triangles per cell.
    static func geometry(cells: Int) -> (vertices: [SIMD2<Float>], indices: [UInt16]) {
        let side = cells + 1
        var vertices: [SIMD2<Float>] = []
        vertices.reserveCapacity(side * side)
        for row in 0 ... cells {
            for column in 0 ... cells {
                vertices.append(SIMD2<Float>(Float(column) / Float(cells) * 4096,
                                             Float(row) / Float(cells) * 4096))
            }
        }
        var indices: [UInt16] = []
        indices.reserveCapacity(cells * cells * 6)
        for row in 0 ..< cells {
            for column in 0 ..< cells {
                let southWest = UInt16(row * side + column)
                let southEast = southWest + 1
                let northWest = southWest + UInt16(side)
                let northEast = northWest + 1
                indices.append(contentsOf: [southWest, southEast, northEast, southWest, northEast, northWest])
            }
        }
        return (vertices, indices)
    }
}
