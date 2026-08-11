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

    /// A tile whose backing arena is a page-scale standalone allocation: the
    /// driver suballocates tiny buffers from an internal pool where
    /// purgeable-state transitions are a no-op, so the fixture must be large
    /// enough to observe them. The observed buffer IS the backing buffer.
    private func makeTile(device: MTLDevice, key: Tile) throws -> (MetalTile, MTLBuffer) {
        let arena = try XCTUnwrap(TileBufferArena(metalDevice: device, length: 64 * 1024))
        let vertices = Array(repeating: TilePipeline.VertexIn(position: SIMD2<Int16>(0, 0), styleIndex: 0),
                             count: 3)
        let ground = TileBuffers.GeometryLayer(vertices: arena.append(vertices),
                                               indices: nil,
                                               styles: nil,
                                               overviewStyleMask: nil,
                                               indexType: .uint16)
        let emptyLayer = TileBuffersFixtures.emptyGeometryLayer()
        let phases = RoadGeometryPhases(shadow: emptyLayer,
                                        casing: emptyLayer,
                                        fill: emptyLayer,
                                        detail: emptyLayer,
                                        overlay: emptyLayer)
        let buffers = TileBuffers(backingBuffer: arena.backingBuffer,
                                  ground: ground,
                                  roads: RoadStructureBuckets(tunnel: phases,
                                                              ground: phases,
                                                              bridge: phases),
                                  bridgeOverlay: emptyLayer,
                                  extruded: TileBuffers.Extruded(vertices: nil,
                                                                 indices: nil,
                                                                 styles: nil,
                                                                 indexType: .uint16),
                                  textLabels: TileBuffers.TextLabels(full: TileBuffersFixtures.emptyTextLabelSet(),
                                                                     reduced: TileBuffersFixtures.emptyTextLabelSet(),
                                                                     minimal: TileBuffersFixtures.emptyTextLabelSet()),
                                  roadLabels: TileBuffersFixtures.emptyRoadLabels())
        return (MetalTile(tile: key, tileBuffers: buffers), arena.backingBuffer)
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

    /// The placement subsystem reports the active set on every rendered frame
    /// (including dirty-gated ones), so a tile that just left the placements
    /// always carries a fresh stamp: the in-flight window is measured from
    /// the frame it actually stopped being drawn, not from the last placement
    /// rebuild hundreds of gated frames earlier.
    func testFreshPerFrameStampsMeasureTheWindowFromTheLastDrawnFrame() throws {
        let device = try makeDevice()
        let key = Tile(x: 7, y: 8, z: 10)
        let (tile, observedBuffer) = try makeTile(device: device, key: key)
        let cache = MemoryMetalTileCache(maxCacheSizeInBytes: 64 * 1024 * 1024,
                                         tileTraceRecorder: TileTraceRecorder())

        cache.setTileData(tile: tile, forKey: key)
        // A long stable stretch: the tile is placed and re-stamped every frame.
        for frameIndex in UInt64(100)...600 {
            cache.recordActiveTiles([key], frameIndex: frameIndex)
        }

        // The tile leaves the placements: the very next sweep must not park
        // it (in-flight frames may still read it), only a sweep past the
        // window may.
        cache.recordActiveTiles([], frameIndex: 601)
        XCTAssertNotEqual(currentPurgeableState(of: observedBuffer), .volatile)
        cache.recordActiveTiles([], frameIndex: 600 + MemoryMetalTileCache.volatileDelayFrames)
        XCTAssertEqual(currentPurgeableState(of: observedBuffer), .volatile)
    }

    /// Activity stamps must stay a subset of the cache keys: the demanded set
    /// contains tiles that may never materialize, and stamping those would
    /// grow the bookkeeping for the process lifetime.
    func testActivityStampsStayBoundedByCacheContents() throws {
        let device = try makeDevice()
        let cache = MemoryMetalTileCache(maxCacheSizeInBytes: 64 * 1024 * 1024,
                                         tileTraceRecorder: TileTraceRecorder())

        let phantomTiles = Set((0..<100).map { Tile(x: $0, y: 0, z: 12) })
        cache.updateProtectedTiles(phantomTiles)
        cache.recordActiveTiles(phantomTiles, frameIndex: 100)
        XCTAssertEqual(cache.trackedActivityStampCount, 0,
                       "Demanded-but-never-materialized tiles must leave no stamp")

        let key = Tile(x: 1, y: 1, z: 10)
        let (tile, _) = try makeTile(device: device, key: key)
        cache.setTileData(tile: tile, forKey: key)
        cache.updateProtectedTiles([])
        cache.recordActiveTiles([key], frameIndex: 101)
        XCTAssertEqual(cache.trackedActivityStampCount, 1)

        cache.removeAll()
        XCTAssertEqual(cache.trackedActivityStampCount, 0,
                       "Removal must drop the stamps with the entries")
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
        if let backingBuffer = tile.tileBuffers.backingBuffer {
            _ = backingBuffer.setPurgeableState(.empty)
        }

        XCTAssertNil(cache.getTile(forKey: key),
                     "A reclaimed tile must read as a cache miss")
        XCTAssertNil(cache.getTile(forKey: key),
                     "The reclaimed entry must be gone, not retried")
        XCTAssertNotEqual(cache.contentVersion, versionBeforeReclaim,
                          "Dropping a reclaimed tile must bump the content version for the demand gate")
    }
}
