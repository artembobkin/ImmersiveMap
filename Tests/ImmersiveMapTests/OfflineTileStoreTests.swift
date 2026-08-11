// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import XCTest
@testable import ImmersiveMap

/// The store is the contract between the standalone offline controller and
/// every map view: both derive the same on-disk location from the tile
/// source, and the pipeline reads what the downloader wrote.
final class OfflineTileStoreTests: XCTestCase {
    private var baseDirectory: URL!

    override func setUpWithError() throws {
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineTileStore-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    private func makeStore(cacheIdentity: UInt64 = 7) -> OfflineTileStore {
        var network = ImmersiveMapSettings.default.tiles.network
        network.cacheIdentity = cacheIdentity
        return OfflineTileStore(network: network, baseDirectory: baseDirectory)
    }

    func testTileRoundTripAndAbsence() throws {
        let store = makeStore()
        let tile = Tile(x: 8186, y: 5448, z: 14)
        XCTAssertNil(store.tileData(for: tile))
        XCTAssertNil(store.storedByteCount(of: tile))
        XCTAssertFalse(store.containsTile(tile))

        let bytes = Data([0x1a, 0x2b, 0x3c])
        try store.writeTile(tile, data: bytes)
        XCTAssertEqual(store.tileData(for: tile), bytes)
        XCTAssertEqual(store.storedByteCount(of: tile), 3)
        XCTAssertTrue(store.containsTile(tile))
    }

    func testDownloadResultMapping() throws {
        let store = makeStore()
        let storedTile = Tile(x: 1, y: 2, z: 3)
        let emptyTile = Tile(x: 2, y: 2, z: 3)
        let missingTile = Tile(x: 3, y: 2, z: 3)
        try store.writeTile(storedTile, data: Data([9]))
        try store.writeEmptyTileMarker(emptyTile)

        XCTAssertEqual(store.downloadResult(for: storedTile), .success(Data([9]), etag: nil))
        XCTAssertEqual(store.downloadResult(for: emptyTile), .failure(.notFound))
        XCTAssertNil(store.downloadResult(for: missingTile))
    }

    func testSameTileSourceResolvesTheSameDirectoryAndADifferentSourceDoesNot() {
        XCTAssertEqual(makeStore(cacheIdentity: 7).rootDirectory,
                       makeStore(cacheIdentity: 7).rootDirectory)
        XCTAssertNotEqual(makeStore(cacheIdentity: 7).rootDirectory,
                          makeStore(cacheIdentity: 8).rootDirectory)
    }

    func testRegionRecordRoundTripSortedByID() throws {
        let store = makeStore()
        XCTAssertTrue(store.regionRecords().isEmpty)

        let makeRecord: (String) -> OfflineStoredRegionRecord = { id in
            OfflineStoredRegionRecord(
                region: ImmersiveMapOfflineRegion(id: id,
                                                  southWest: GeoCoordinate(latitude: 1, longitude: 2),
                                                  northEast: GeoCoordinate(latitude: 3, longitude: 4),
                                                  zoomLevels: 0...5),
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                isComplete: true,
                storedTileCount: 12,
                failedTileCount: 1,
                byteCount: 34_567)
        }
        try store.writeRegionRecord(makeRecord("b"))
        try store.writeRegionRecord(makeRecord("a"))

        let records = store.regionRecords()
        XCTAssertEqual(records.map(\.region.id), ["a", "b"])
        XCTAssertEqual(records.first, makeRecord("a"))

        store.removeRegionRecord(id: "a")
        XCTAssertEqual(store.regionRecords().map(\.region.id), ["b"])
    }

    func testPruneKeepsOnlyTheKeptTiles() throws {
        let store = makeStore()
        let kept = Tile(x: 0, y: 0, z: 1)
        let keptDeep = Tile(x: 5, y: 6, z: 7)
        let dropped = Tile(x: 1, y: 1, z: 1)
        let droppedAloneInZoom = Tile(x: 3, y: 3, z: 2)
        for tile in [kept, keptDeep, dropped, droppedAloneInZoom] {
            try store.writeTile(tile, data: Data([1]))
        }

        let removedCount = store.pruneTiles(keeping: [kept, keptDeep])

        XCTAssertEqual(removedCount, 2)
        XCTAssertTrue(store.containsTile(kept))
        XCTAssertTrue(store.containsTile(keptDeep))
        XCTAssertFalse(store.containsTile(dropped))
        XCTAssertFalse(store.containsTile(droppedAloneInZoom))
    }

    func testMeasureStoredTilesCountsOnlyWhatExists() throws {
        let store = makeStore()
        let stored = Tile(x: 1, y: 1, z: 4)
        let empty = Tile(x: 2, y: 1, z: 4)
        let missing = Tile(x: 3, y: 1, z: 4)
        try store.writeTile(stored, data: Data(count: 10))
        try store.writeEmptyTileMarker(empty)

        let measured = store.measureStoredTiles(of: [stored, empty, missing])
        XCTAssertEqual(measured.storedTileCount, 2)
        XCTAssertEqual(measured.byteCount, 10)
    }

    func testRemoveEverythingDeletesTheNamespace() throws {
        let store = makeStore()
        try store.writeTile(Tile(x: 0, y: 0, z: 0), data: Data([1]))
        try store.writeRegionRecord(OfflineStoredRegionRecord(
            region: ImmersiveMapOfflineRegion(id: "r",
                                              southWest: GeoCoordinate(latitude: 0, longitude: 0),
                                              northEast: GeoCoordinate(latitude: 1, longitude: 1),
                                              zoomLevels: 0...0),
            createdAt: Date(),
            isComplete: false,
            storedTileCount: 0,
            failedTileCount: 0,
            byteCount: 0))

        store.removeEverything()

        XCTAssertFalse(FileManager.default.fileExists(atPath: store.rootDirectory.path))
        XCTAssertTrue(store.regionRecords().isEmpty)
        XCTAssertNil(store.tileData(for: Tile(x: 0, y: 0, z: 0)))
    }
}
