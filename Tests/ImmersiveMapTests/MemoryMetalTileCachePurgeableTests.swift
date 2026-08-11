// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import XCTest

/// Purgeable lifecycle of cached tiles: buffers outside the demanded, pinned,
/// and placed sets go volatile after the in-flight window, restore on reuse,
/// and a tile whose volatile buffers the OS reclaimed drops out as a miss.
final class MemoryMetalTileCachePurgeableTests: XCTestCase {
    private func makeDevice() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable in this test environment")
        }
        return device
    }

    /// A tile with two dedicated buffers (ground vertices and indices), so
    /// purgeable-state assertions observe exactly the buffers of this tile.
    /// Page-scale allocations: the driver suballocates tiny buffers from an
    /// internal pool where purgeable-state transitions are a no-op, so the
    /// fixture must use standalone allocations to observe them.
    private func makeTile(device: MTLDevice, key: Tile) throws -> (MetalTile, MTLBuffer) {
        let verticesBuffer = try XCTUnwrap(device.makeBuffer(length: 64 * 1024))
        let indicesBuffer = try XCTUnwrap(device.makeBuffer(length: 64 * 1024))

        let emptyLayer = TileBuffers.GeometryLayer(verticesBuffer: nil,
                                                   indicesBuffer: nil,
                                                   stylesBuffer: nil,
                                                   overviewStyleMaskBuffer: nil,
                                                   indicesCount: 0,
                                                   verticesCount: 0,
                                                   indexType: .uint16)
        let ground = TileBuffers.GeometryLayer(verticesBuffer: verticesBuffer,
                                               indicesBuffer: indicesBuffer,
                                               stylesBuffer: nil,
                                               overviewStyleMaskBuffer: nil,
                                               indicesCount: 3,
                                               verticesCount: 3,
                                               indexType: .uint16)
        let phases = RoadGeometryPhases(shadow: emptyLayer,
                                        casing: emptyLayer,
                                        fill: emptyLayer,
                                        detail: emptyLayer,
                                        overlay: emptyLayer)
        let emptyTextLabelSet = TileBuffers.TextLabelSet(placementInputs: [],
                                                         labelsByStyleRuns: [],
                                                         poiIconRuns: [])
        let buffers = TileBuffers(ground: ground,
                                  roads: RoadStructureBuckets(tunnel: phases,
                                                              ground: phases,
                                                              bridge: phases),
                                  bridgeOverlay: emptyLayer,
                                  extruded: TileBuffers.Extruded(verticesBuffer: nil,
                                                                 indicesBuffer: nil,
                                                                 stylesBuffer: nil,
                                                                 indicesCount: 0,
                                                                 verticesCount: 0,
                                                                 indexType: .uint16),
                                  textLabels: TileBuffers.TextLabels(full: emptyTextLabelSet,
                                                                     reduced: emptyTextLabelSet,
                                                                     minimal: emptyTextLabelSet),
                                  roadLabels: TileBuffers.RoadLabels(pathInputs: [],
                                                                     pathRanges: [],
                                                                     pathLabels: [],
                                                                     labelStyle: nil,
                                                                     localGlyphVerticesBuffer: nil,
                                                                     localGlyphVertexCount: 0,
                                                                     glyphBounds: [],
                                                                     glyphBoundRanges: [],
                                                                     sizes: [],
                                                                     anchorRanges: [],
                                                                     anchors: []))
        return (MetalTile(tile: key, tileBuffers: buffers), verticesBuffer)
    }

    private func currentPurgeableState(of buffer: MTLBuffer) -> MTLPurgeableState {
        buffer.setPurgeableState(.keepCurrent)
    }

    func testIdleTileGoesVolatileAndRestoresOnLookup() throws {
        let device = try makeDevice()
        let key = Tile(x: 1, y: 2, z: 10)
        let (tile, observedBuffer) = try makeTile(device: device, key: key)
        let cache = MemoryMetalTileCache(maxCacheSizeInBytes: 64 * 1024 * 1024,
                                         tileTraceRecorder: TileTraceRecorder())

        cache.setTileData(tile: tile, forKey: key)
        cache.recordActiveTiles([], frameIndex: 100)
        XCTAssertEqual(currentPurgeableState(of: observedBuffer), .volatile)

        let restored = cache.getTile(forKey: key)
        XCTAssertNotNil(restored)
        XCTAssertEqual(currentPurgeableState(of: observedBuffer), .nonVolatile)
    }

    func testDemandedActiveAndFreshTilesStayNonVolatile() throws {
        let device = try makeDevice()
        let key = Tile(x: 3, y: 4, z: 10)
        let (tile, observedBuffer) = try makeTile(device: device, key: key)
        let cache = MemoryMetalTileCache(maxCacheSizeInBytes: 64 * 1024 * 1024,
                                         tileTraceRecorder: TileTraceRecorder())

        cache.setTileData(tile: tile, forKey: key)
        cache.updateProtectedTiles([key])
        cache.recordActiveTiles([], frameIndex: 100)
        XCTAssertNotEqual(currentPurgeableState(of: observedBuffer), .volatile,
                          "A demanded tile must never go volatile")

        cache.updateProtectedTiles([])
        cache.recordActiveTiles([key], frameIndex: 200)
        XCTAssertNotEqual(currentPurgeableState(of: observedBuffer), .volatile,
                          "A placed (active) tile must never go volatile")

        cache.recordActiveTiles([], frameIndex: 201)
        XCTAssertNotEqual(currentPurgeableState(of: observedBuffer), .volatile,
                          "The in-flight window must pass before a tile goes volatile")

        cache.recordActiveTiles([], frameIndex: 200 + MemoryMetalTileCache.volatileDelayFrames)
        XCTAssertEqual(currentPurgeableState(of: observedBuffer), .volatile)
    }

    func testReclaimedTileDropsOutAsMiss() throws {
        let device = try makeDevice()
        let key = Tile(x: 5, y: 6, z: 10)
        let (tile, _) = try makeTile(device: device, key: key)
        let cache = MemoryMetalTileCache(maxCacheSizeInBytes: 64 * 1024 * 1024,
                                         tileTraceRecorder: TileTraceRecorder())

        cache.setTileData(tile: tile, forKey: key)
        let versionBeforeReclaim = cache.contentVersion
        cache.recordActiveTiles([], frameIndex: 100)

        // Simulate the OS reclaiming the volatile allocation.
        tile.tileBuffers.forEachBuffer { buffer in
            _ = buffer.setPurgeableState(.empty)
        }

        XCTAssertNil(cache.getTile(forKey: key),
                     "A reclaimed tile must read as a cache miss")
        XCTAssertNil(cache.getTile(forKey: key),
                     "The reclaimed entry must be gone, not retried")
        XCTAssertNotEqual(cache.contentVersion, versionBeforeReclaim,
                          "Dropping a reclaimed tile must bump the content version for the demand gate")
    }
}
