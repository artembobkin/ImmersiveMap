// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import simd
import XCTest

/// The raster tiles' pieces that need no GPU: the grid a texture is drawn
/// on, and the settings.
final class RasterTileTests: XCTestCase {
    // MARK: - The texture's bytes

    /// The grid covers the tile's extent, counter-clockwise like every tile
    /// triangle, so the surfaces' back-face culling keeps it.
    func testTheGridCoversTheTileCounterClockwise() {
        let cells = 4
        let geometry = RasterTileGrid.geometry(cells: cells)
        XCTAssertEqual(geometry.vertices.count, (cells + 1) * (cells + 1))
        XCTAssertEqual(geometry.indices.count, cells * cells * 6)
        XCTAssertEqual(geometry.vertices.first, SIMD2<Float>(0, 0))
        XCTAssertEqual(geometry.vertices.last, SIMD2<Float>(4096, 4096))
        var area: Float = 0
        for triangle in stride(from: 0, to: geometry.indices.count, by: 3) {
            let a = geometry.vertices[Int(geometry.indices[triangle])]
            let b = geometry.vertices[Int(geometry.indices[triangle + 1])]
            let c = geometry.vertices[Int(geometry.indices[triangle + 2])]
            let signedArea = ((b - a).x * (c - a).y - (b - a).y * (c - a).x) / 2
            XCTAssertGreaterThan(signedArea, 0, "triangle \(triangle / 3) is counter-clockwise")
            area += signedArea
        }
        XCTAssertEqual(area, 4096 * 4096, accuracy: 1, "the cells cover the tile once")
    }

    /// The sphere's coarse tiles bend as their geometry does, the deep ones
    /// keep the grid a heightmap needs, and every grid fits 16-bit indices.
    func testTheGridFollowsTheSpheresSplit() {
        XCTAssertEqual(RasterTileGrid.cells(forTileZoom: 0), 64)
        XCTAssertEqual(RasterTileGrid.cells(forTileZoom: 3), 32)
        XCTAssertEqual(RasterTileGrid.cells(forTileZoom: 5), RasterTileGrid.minimumCells)
        XCTAssertEqual(RasterTileGrid.cells(forTileZoom: 14), RasterTileGrid.minimumCells)
        for zoom in 0 ... 22 {
            let cells = RasterTileGrid.cells(forTileZoom: zoom)
            XCTAssertLessThanOrEqual((cells + 1) * (cells + 1), Int(UInt16.max))
        }
    }

    // MARK: - The file

    /// On the relief the grid is at least the zoom's flattening grid, and
    /// never past what 16-bit indices address.
    func testTheGridOnTheReliefIsAsFineAsTheFlattenings() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let grid = RasterTileGrid(device: device)
        XCTAssertEqual(try XCTUnwrap(grid.mesh(forTileZoom: 10)).indexCount, RasterTileGrid.cells(forTileZoom: 10) * RasterTileGrid.cells(forTileZoom: 10) * 6)
        XCTAssertEqual(try XCTUnwrap(grid.mesh(forTileZoom: 10, atLeast: 128)).indexCount, 128 * 128 * 6)
        XCTAssertEqual(try XCTUnwrap(grid.mesh(forTileZoom: 10, atLeast: 256)).indexCount, 255 * 255 * 6, "16-bit indices")
    }

    // MARK: - The settings

    func testTheModifierLeavesTheOtherValuesAsConfigured() {
        let base = FixtureTiles.tilelessSettings()
        let changed = base.tileRasterization(mipLevelBias: 0.5)
        XCTAssertEqual(changed.tiles.rasterization.mipLevelBias, 0.5)
        XCTAssertEqual(changed.tiles.rasterization.maximumAnisotropy, base.tiles.rasterization.maximumAnisotropy)
    }

    /// The sampler is built with the renderer, and the prepared tiles do
    /// not depend on these settings.
    func testAChangeRecreatesTheRendererAndKeepsTheCaches() {
        let old = FixtureTiles.tilelessSettings()
        let new = old.tileRasterization(maximumAnisotropy: 4)
        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: old, to: new)
        XCTAssertTrue(plan.requiresRendererRecreation)
        XCTAssertFalse(plan.actions.contains(.invalidateCaches))
        XCTAssertFalse(plan.actions.contains(.rebuildPreparedData))
    }
}
