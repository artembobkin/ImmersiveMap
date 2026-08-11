// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import XCTest
@testable import ImmersiveMap

/// The public controller contract: validation before any network work,
/// observable progress, persistence across relaunches, resume fetching only
/// what is missing, and removal that respects overlapping regions.
@MainActor
final class ImmersiveMapOfflineControllerTests: XCTestCase {
    // An immutable Sendable stored property so the nonisolated XCTestCase
    // lifecycle (deinit) can reach it from outside the main actor.
    private let baseDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ImmersiveMapOfflineController-\(UUID().uuidString)")

    deinit {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    private func makeController(maximumTileZoomLevel: Int? = 14,
                                fetchTile: @escaping OfflineRegionDownloader.FetchTile = { _ in
                                    .success(Data([1]), etag: nil)
                                }) -> ImmersiveMapOfflineController {
        ImmersiveMapOfflineController(network: ImmersiveMapSettings.default.tiles.network,
                                      maximumTileZoomLevel: maximumTileZoomLevel,
                                      baseDirectory: baseDirectory,
                                      makeFetchTile: { fetchTile },
                                      maxConcurrentFetches: 2,
                                      pause: { _ in },
                                      progressReportStride: 1)
    }

    private func makeWorldRegion(id: String = "world", zoomLevels: ClosedRange<Int> = 0...2) -> ImmersiveMapOfflineRegion {
        ImmersiveMapOfflineRegion(id: id,
                                  southWest: GeoCoordinate(latitude: -85, longitude: -180),
                                  northEast: GeoCoordinate(latitude: 85, longitude: 180),
                                  zoomLevels: zoomLevels)
    }

    private func awaitDownload(_ controller: ImmersiveMapOfflineController, regionID: String) async {
        await controller.activeDownloadTaskForTesting(regionID: regionID)?.value
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<300 {
            if condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    func testDownloadCompletesUpdatesStatusAndPersists() async throws {
        let controller = makeController()
        var changeCount = 0
        controller.onRegionsChanged = { changeCount += 1 }

        try controller.download(makeWorldRegion())
        XCTAssertEqual(controller.status(forRegionID: "world")?.phase, .downloading)
        await awaitDownload(controller, regionID: "world")

        guard let status = controller.status(forRegionID: "world") else {
            return XCTFail("Expected a status for the downloaded region")
        }
        XCTAssertEqual(status.phase, .complete)
        XCTAssertEqual(status.expectedTileCount, 21)
        XCTAssertEqual(status.storedTileCount, 21)
        XCTAssertEqual(status.failedTileCount, 0)
        XCTAssertEqual(status.byteCount, 21)
        XCTAssertEqual(status.fractionCompleted, 1.0)
        XCTAssertGreaterThan(changeCount, 0)

        // A fresh controller over the same directory sees the region without
        // ever constructing a transport.
        let reloaded = ImmersiveMapOfflineController(
            network: ImmersiveMapSettings.default.tiles.network,
            maximumTileZoomLevel: 14,
            baseDirectory: baseDirectory,
            makeFetchTile: {
                { _ in
                    XCTFail("A controller that only lists regions must not fetch")
                    return .failure(.network)
                }
            })
        XCTAssertEqual(reloaded.regions.map(\.id), ["world"])
        XCTAssertEqual(reloaded.regions.first?.phase, .complete)
        XCTAssertEqual(reloaded.regions.first?.byteCount, 21)
    }

    func testDownloadValidatesBeforeStartingAnything() {
        let controller = makeController()
        controller.maximumTileCountPerDownload = 10

        XCTAssertThrowsError(try controller.download(makeWorldRegion(zoomLevels: 0...4))) { error in
            guard case let ImmersiveMapOfflineError.regionTooLarge(tileCount, maximumTileCount) = error else {
                return XCTFail("Expected regionTooLarge, got \(error)")
            }
            XCTAssertEqual(tileCount, 1 + 4 + 16 + 64 + 256)
            XCTAssertEqual(maximumTileCount, 10)
        }

        let inverted = ImmersiveMapOfflineRegion(id: "inverted",
                                                 southWest: GeoCoordinate(latitude: 10, longitude: 0),
                                                 northEast: GeoCoordinate(latitude: 5, longitude: 5),
                                                 zoomLevels: 0...2)
        XCTAssertThrowsError(try controller.download(inverted)) { error in
            XCTAssertEqual(error as? ImmersiveMapOfflineError, .emptyRegion)
        }
        XCTAssertTrue(controller.regions.isEmpty)
    }

    func testZoomLevelsClampToTheProviderMaximum() async throws {
        let controller = makeController(maximumTileZoomLevel: 1)
        try controller.download(makeWorldRegion(zoomLevels: 0...5))
        await awaitDownload(controller, regionID: "world")

        guard let status = controller.status(forRegionID: "world") else {
            return XCTFail("Expected a status for the downloaded region")
        }
        XCTAssertEqual(status.region.zoomLevels, 0...1)
        XCTAssertEqual(status.expectedTileCount, 5)
        XCTAssertEqual(status.phase, .complete)
    }

    func testFailedTilesLeaveTheRegionIncompleteAndResumeFetchesOnlyMissing() async throws {
        let failing = Locked(true)
        let fetched = Locked([Tile]())
        let controller = makeController(fetchTile: { tile in
            fetched.withLock { $0.append(tile) }
            if failing.withLock({ $0 }), tile.z == 2, tile.x == 0, tile.y == 0 {
                return .failure(.network)
            }
            return .success(Data([1]), etag: nil)
        })

        try controller.download(makeWorldRegion())
        await awaitDownload(controller, regionID: "world")
        XCTAssertEqual(controller.status(forRegionID: "world")?.phase, .incomplete)
        XCTAssertEqual(controller.status(forRegionID: "world")?.failedTileCount, 1)
        XCTAssertEqual(controller.status(forRegionID: "world")?.storedTileCount, 20)

        failing.withLock { $0 = false }
        fetched.withLock { $0 = [] }
        try controller.download(makeWorldRegion())
        await awaitDownload(controller, regionID: "world")

        XCTAssertEqual(controller.status(forRegionID: "world")?.phase, .complete)
        XCTAssertEqual(controller.status(forRegionID: "world")?.storedTileCount, 21)
        // Resume touched only the one missing tile.
        XCTAssertEqual(fetched.withLock { $0 }, [Tile(x: 0, y: 0, z: 2)])
    }

    func testRemoveRegionKeepsTilesSharedWithAnotherRegion() async throws {
        let controller = makeController()
        try controller.download(makeWorldRegion(id: "shallow", zoomLevels: 0...1))
        await awaitDownload(controller, regionID: "shallow")
        try controller.download(makeWorldRegion(id: "deep", zoomLevels: 0...2))
        await awaitDownload(controller, regionID: "deep")

        let store = OfflineTileStore(network: ImmersiveMapSettings.default.tiles.network,
                                     baseDirectory: baseDirectory)
        XCTAssertTrue(store.containsTile(Tile(x: 3, y: 3, z: 2)))

        controller.removeRegion(regionID: "deep")
        XCTAssertEqual(controller.regions.map(\.id), ["shallow"])

        // The prune sweep runs in the background: zoom 2 tiles belong only to
        // the removed region, zoom 0 and 1 tiles survive for the other one.
        let pruned = await waitUntil { store.containsTile(Tile(x: 3, y: 3, z: 2)) == false }
        XCTAssertTrue(pruned)
        XCTAssertTrue(store.containsTile(Tile(x: 0, y: 0, z: 0)))
        XCTAssertTrue(store.containsTile(Tile(x: 1, y: 1, z: 1)))
        XCTAssertTrue(store.regionRecords().map(\.region.id) == ["shallow"])
    }

    func testRemoveAllRegionsDeletesTheNamespace() async throws {
        let controller = makeController()
        try controller.download(makeWorldRegion())
        await awaitDownload(controller, regionID: "world")

        controller.removeAllRegions()

        XCTAssertTrue(controller.regions.isEmpty)
        let store = OfflineTileStore(network: ImmersiveMapSettings.default.tiles.network,
                                     baseDirectory: baseDirectory)
        let removed = await waitUntil { FileManager.default.fileExists(atPath: store.rootDirectory.path) == false }
        XCTAssertTrue(removed)
    }

    func testInterruptedDownloadIsRecountedFromDiskOnRelaunch() async throws {
        // Simulate an interrupted download: tiles on disk, but a record that
        // never got its final counter write.
        let store = OfflineTileStore(network: ImmersiveMapSettings.default.tiles.network,
                                     baseDirectory: baseDirectory)
        let region = makeWorldRegion(zoomLevels: 0...1)
        for tile in OfflineRegionTileMath.tiles(in: region) {
            try store.writeTile(tile, data: Data([1, 2]))
        }
        try store.writeRegionRecord(OfflineStoredRegionRecord(region: region,
                                                              createdAt: Date(),
                                                              isComplete: false,
                                                              storedTileCount: 0,
                                                              failedTileCount: 0,
                                                              byteCount: 0,
                                                              wasBlockedByAuthorization: false))

        let controller = makeController()
        let recounted = await waitUntil {
            controller.status(forRegionID: "world")?.phase == .complete
        }
        XCTAssertTrue(recounted)
        XCTAssertEqual(controller.status(forRegionID: "world")?.storedTileCount, 5)
        XCTAssertEqual(controller.status(forRegionID: "world")?.byteCount, 10)
    }

    func testAuthorizationFailureIsSurfacedAndPersisted() async throws {
        let controller = makeController(fetchTile: { _ in .failure(.unauthorized) })
        try controller.download(makeWorldRegion())
        await awaitDownload(controller, regionID: "world")

        guard let status = controller.status(forRegionID: "world") else {
            return XCTFail("Expected a status for the aborted region")
        }
        XCTAssertEqual(status.phase, .incomplete)
        XCTAssertTrue(status.isBlockedByAuthorization)

        // The cause survives a relaunch.
        let reloaded = ImmersiveMapOfflineController(
            network: ImmersiveMapSettings.default.tiles.network,
            maximumTileZoomLevel: 14,
            baseDirectory: baseDirectory,
            makeFetchTile: { { _ in .failure(.network) } })
        XCTAssertEqual(reloaded.regions.first?.isBlockedByAuthorization, true)

        // A successful re-download clears it.
        let recovered = ImmersiveMapOfflineController(
            network: ImmersiveMapSettings.default.tiles.network,
            maximumTileZoomLevel: 14,
            baseDirectory: baseDirectory,
            makeFetchTile: { { _ in .success(Data([1]), etag: nil) } },
            pause: { _ in })
        try recovered.download(makeWorldRegion())
        await recovered.activeDownloadTaskForTesting(regionID: "world")?.value
        XCTAssertEqual(recovered.status(forRegionID: "world")?.phase, .complete)
        XCTAssertEqual(recovered.status(forRegionID: "world")?.isBlockedByAuthorization, false)
    }

    func testRemoveWhileDownloadingAllowsAnImmediateRedownload() async throws {
        let gate = Locked(false)
        let controller = makeController(fetchTile: { _ in
            while gate.withLock({ $0 }) == false {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return .success(Data([1]), etag: nil)
        })

        try controller.download(makeWorldRegion(zoomLevels: 0...1))
        // Remove mid-download, then immediately download the same id again:
        // the drained old task must neither block the new download nor
        // clobber its state when it finishes.
        controller.removeRegion(regionID: "world")
        XCTAssertNil(controller.status(forRegionID: "world"))
        try controller.download(makeWorldRegion(zoomLevels: 0...1))
        XCTAssertEqual(controller.status(forRegionID: "world")?.phase, .downloading)

        gate.withLock { $0 = true }
        await awaitDownload(controller, regionID: "world")
        let settled = await waitUntil {
            controller.status(forRegionID: "world")?.phase == .complete
        }
        XCTAssertTrue(settled)
        XCTAssertEqual(controller.status(forRegionID: "world")?.storedTileCount, 5)
    }

    func testDownloadStartedDuringPruneSweepKeepsItsTiles() async throws {
        let controller = makeController()
        try controller.download(makeWorldRegion(id: "first", zoomLevels: 0...2))
        await awaitDownload(controller, regionID: "first")

        // The removal sweep runs in the background; a download started while
        // it is pending must wait it out rather than lose fresh tiles.
        controller.removeRegion(regionID: "first")
        try controller.download(makeWorldRegion(id: "second", zoomLevels: 0...2))
        await controller.pruneSweepTaskForTesting()?.value
        await awaitDownload(controller, regionID: "second")

        XCTAssertEqual(controller.status(forRegionID: "second")?.phase, .complete)
        let store = OfflineTileStore(network: ImmersiveMapSettings.default.tiles.network,
                                     baseDirectory: baseDirectory)
        for tile in OfflineRegionTileMath.tiles(in: makeWorldRegion(id: "second", zoomLevels: 0...2)) {
            XCTAssertTrue(store.containsTile(tile), "Missing tile \(tile) after sweep")
        }
    }

    func testDownloadWhileDownloadingIsANoOp() async throws {
        let gate = Locked(false)
        let fetchCount = Locked(0)
        let controller = makeController(fetchTile: { _ in
            fetchCount.withLock { $0 += 1 }
            while gate.withLock({ $0 }) == false {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return .success(Data([1]), etag: nil)
        })

        try controller.download(makeWorldRegion(zoomLevels: 0...0))
        // A second download of the same id while the first is running must
        // not start a second run over the same tiles.
        try controller.download(makeWorldRegion(zoomLevels: 0...0))
        XCTAssertEqual(controller.status(forRegionID: "world")?.phase, .downloading)

        gate.withLock { $0 = true }
        await awaitDownload(controller, regionID: "world")
        XCTAssertEqual(controller.status(forRegionID: "world")?.phase, .complete)
        XCTAssertEqual(fetchCount.withLock { $0 }, 1)
    }
}
