// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The raster tiles' pieces that need no GPU: the bytes of a texture, the
/// grid it is drawn on, the file it is kept in, and the settings.
final class RasterTileTests: XCTestCase {
    // MARK: - The texture's bytes

    /// Every level from the full edge down to one texel, packed one after
    /// the other.
    func testTheLevelsArePackedFromTheFullEdgeDown() {
        XCTAssertEqual(RasterTileLayout.levelCount(size: 256), 9)
        XCTAssertEqual(RasterTileLayout.levelCount(size: 64), 7)
        XCTAssertEqual(RasterTileLayout.edge(size: 256, level: 8), 1)
        let offsets = RasterTileLayout.levelOffsets(size: 256)
        XCTAssertEqual(offsets.count, 9)
        XCTAssertEqual(offsets[0], 0)
        XCTAssertEqual(offsets[1], 256 * 256 * 4)
        XCTAssertEqual(offsets[2], 256 * 256 * 4 + 128 * 128 * 4)
        let total = RasterTileLayout.totalByteCount(size: 256)
        XCTAssertEqual(total, offsets[8] + 4, "the last level is one texel")
        XCTAssertEqual(Double(total), Double(256 * 256 * 4) * 4 / 3, accuracy: 4, "a mip chain is a third over its first level")
        for size in FlatRingRules.rasterSizes {
            XCTAssertEqual(RasterTileLayout.levelOffsets(size: size).count, RasterTileLayout.levelCount(size: size))
        }
    }

    // MARK: - The grid

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

    /// A raster tile's file lives in its prepared namespace, a directory a
    /// size and fade zoom, under the name the availability index reads.
    func testTheFileLivesInThePreparedNamespace() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("RasterTileTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let settings = FixtureTiles.tilelessSettings()
        let identity = PreparedTileCacheIdentity(preparedFormatVersion: PreparedTileDiskCaching.preparedFormatVersion,
                                                 styleRevision: 1,
                                                 tileSourceRevision: 2,
                                                 textRevision: 3,
                                                 labelLanguage: settings.labels.language,
                                                 labelFallbackPolicy: settings.labels.fallbackPolicy,
                                                 capitalMaximumZoom: 0,
                                                 cityMaximumZoom: 0,
                                                 smallSettlementMaximumZoom: 0,
                                                 landmarkMinimumZoom: 0,
                                                 addTestBorders: false,
                                                 labelsEnabled: true)
        let transport = InlinePreparedTileGeometryTransport()
        let cache = RasterTileDiskCache(config: settings,
                                        cacheIdentity: identity,
                                        geometryTransport: transport,
                                        baseCachesDirectory: base)
        XCTAssertEqual(cache.fileFormat, .plain)
        let key = RasterTileKey(tile: Tile(x: 5, y: 7, z: 9), size: 256, fadeZoom: 13)
        let url = cache.fileURL(for: key)
        let namespace = PreparedTileDiskCaching.namespaceDirectory(
            rootDirectory: PreparedTileDiskCaching.rootDirectory(baseCachesDirectory: base),
            cacheIdentity: identity,
            geometryTransport: transport)
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL,
                       namespace.standardizedFileURL)
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent,
                       "raster-v\(RasterTileDiskCache.formatVersion)-256-z13")
        XCTAssertEqual(PreparedTileAvailabilityIndex.tile(forIndexedFileName: url.lastPathComponent), key.tile)
        XCTAssertNil(PreparedTileAvailabilityIndex.tile(forIndexedFileName: url.lastPathComponent + ".tmp-1"))
        XCTAssertNotEqual(cache.fileURL(for: RasterTileKey(tile: key.tile, size: 128, fadeZoom: 13)), url,
                          "a size is a file of its own")
        XCTAssertNotEqual(cache.fileURL(for: RasterTileKey(tile: key.tile, size: 256, fadeZoom: 12)), url,
                          "a fade zoom is a file of its own")
    }

    // MARK: - The settings

    func testTheModifierLeavesTheOtherValuesAsConfigured() {
        let base = FixtureTiles.tilelessSettings()
        let changed = base.tileRasterization(bakesPerFrame: 2, mipLevelBias: 0.5)
        XCTAssertEqual(changed.tiles.rasterization.bakesPerFrame, 2)
        XCTAssertEqual(changed.tiles.rasterization.mipLevelBias, 0.5)
        XCTAssertEqual(changed.tiles.rasterization.memoryBudgetInBytes, base.tiles.rasterization.memoryBudgetInBytes)
        XCTAssertEqual(changed.tiles.rasterization.maximumAnisotropy, base.tiles.rasterization.maximumAnisotropy)
    }

    /// The store and its sampler are built with the renderer, and the
    /// textures on disk do not depend on these settings.
    func testAChangeRecreatesTheRendererAndKeepsTheCaches() {
        let old = FixtureTiles.tilelessSettings()
        let new = old.tileRasterization(maximumAnisotropy: 4)
        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: old, to: new)
        XCTAssertTrue(plan.requiresRendererRecreation)
        XCTAssertFalse(plan.actions.contains(.invalidateCaches))
        XCTAssertFalse(plan.actions.contains(.rebuildPreparedData))
    }
}
