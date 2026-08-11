// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import XCTest
@testable import ImmersiveMap

/// The downloader's promises: resume never refetches, empty tiles complete a
/// region, transient failures retry, authorization failures abort instead of
/// burning through the whole region, and cancellation keeps what landed.
final class OfflineRegionDownloaderTests: XCTestCase {
    private var baseDirectory: URL!

    override func setUpWithError() throws {
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OfflineRegionDownloader-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    private func makeStore() -> OfflineTileStore {
        OfflineTileStore(network: ImmersiveMapSettings.default.tiles.network,
                         baseDirectory: baseDirectory)
    }

    private func makeTiles(count: Int) -> [Tile] {
        (0..<count).map { Tile(x: $0, y: 0, z: 10) }
    }

    private func makeDownloader(store: OfflineTileStore,
                                fetchTile: @escaping OfflineRegionDownloader.FetchTile,
                                onProgress: @escaping @Sendable (OfflineRegionDownloader.Progress) -> Void = { _ in })
        -> OfflineRegionDownloader {
        OfflineRegionDownloader(store: store,
                                fetchTile: fetchTile,
                                maxConcurrentFetches: 2,
                                pause: { _ in },
                                onProgress: onProgress,
                                progressReportStride: 1)
    }

    func testDownloadsEveryTileAndCompletes() async throws {
        let store = makeStore()
        let fetchCount = Locked(0)
        let downloader = makeDownloader(store: store) { tile in
            fetchCount.withLock { $0 += 1 }
            return .success(Data([UInt8(tile.x)]), etag: nil)
        }

        let summary = await downloader.run(tiles: makeTiles(count: 9))

        XCTAssertTrue(summary.isComplete)
        XCTAssertFalse(summary.wasBlockedByAuthorization)
        XCTAssertEqual(summary.progress.storedTileCount, 9)
        XCTAssertEqual(summary.progress.failedTileCount, 0)
        XCTAssertEqual(summary.progress.byteCount, 9)
        XCTAssertEqual(fetchCount.withLock { $0 }, 9)
        XCTAssertEqual(store.tileData(for: Tile(x: 3, y: 0, z: 10)), Data([3]))
    }

    func testResumeSkipsStoredTilesWithoutFetching() async throws {
        let store = makeStore()
        let tiles = makeTiles(count: 6)
        try store.writeTile(tiles[0], data: Data([7, 7]))
        try store.writeEmptyTileMarker(tiles[1])

        let fetched = Locked([Tile]())
        let downloader = makeDownloader(store: store) { tile in
            fetched.withLock { $0.append(tile) }
            return .success(Data([1]), etag: nil)
        }

        let summary = await downloader.run(tiles: tiles)

        XCTAssertTrue(summary.isComplete)
        XCTAssertEqual(summary.progress.storedTileCount, 6)
        // Skipped tiles still contribute their on-disk size to the total.
        XCTAssertEqual(summary.progress.byteCount, 2 + 4)
        XCTAssertEqual(Set(fetched.withLock { $0 }), Set(tiles[2...]))
        // The already stored bytes were not overwritten.
        XCTAssertEqual(store.tileData(for: tiles[0]), Data([7, 7]))
    }

    func testEmptySourceTilesBecomeMarkersAndStillComplete() async {
        let store = makeStore()
        let downloader = makeDownloader(store: store) { tile in
            tile.x % 2 == 0 ? .failure(.notFound) : .success(Data([1]), etag: nil)
        }

        let summary = await downloader.run(tiles: makeTiles(count: 4))

        XCTAssertTrue(summary.isComplete)
        XCTAssertEqual(summary.progress.storedTileCount, 4)
        XCTAssertEqual(store.tileData(for: Tile(x: 0, y: 0, z: 10)), Data())
        XCTAssertEqual(store.downloadResult(for: Tile(x: 0, y: 0, z: 10)), .failure(.notFound))
    }

    func testTransientFailureRetriesAndSucceeds() async {
        let store = makeStore()
        let attempts = Locked([Tile: Int]())
        let downloader = makeDownloader(store: store) { tile in
            let attempt = attempts.withLock { counts -> Int in
                counts[tile, default: 0] += 1
                return counts[tile]!
            }
            return attempt == 1 ? .failure(.network) : .success(Data([5]), etag: nil)
        }

        let summary = await downloader.run(tiles: makeTiles(count: 3))

        XCTAssertTrue(summary.isComplete)
        XCTAssertEqual(summary.progress.storedTileCount, 3)
        XCTAssertEqual(attempts.withLock { $0.values.max() }, 2)
    }

    func testPersistentFailureCountsTheTileAndFinishesIncomplete() async {
        let store = makeStore()
        let failingTile = Tile(x: 2, y: 0, z: 10)
        let attempts = Locked(0)
        let downloader = makeDownloader(store: store) { tile in
            if tile == failingTile {
                attempts.withLock { $0 += 1 }
                return .failure(.server(statusCode: 503))
            }
            return .success(Data([1]), etag: nil)
        }

        let summary = await downloader.run(tiles: makeTiles(count: 5))

        XCTAssertFalse(summary.isComplete)
        XCTAssertFalse(summary.wasBlockedByAuthorization)
        XCTAssertEqual(summary.progress.storedTileCount, 4)
        XCTAssertEqual(summary.progress.failedTileCount, 1)
        XCTAssertEqual(attempts.withLock { $0 }, 3)
        XCTAssertFalse(store.containsTile(failingTile))
    }

    func testAuthorizationFailureAbortsInsteadOfFailingEveryTile() async {
        let store = makeStore()
        let fetchCount = Locked(0)
        let downloader = OfflineRegionDownloader(store: store,
                                                 fetchTile: { _ in
                                                     fetchCount.withLock { $0 += 1 }
                                                     return .failure(.unauthorized)
                                                 },
                                                 maxConcurrentFetches: 1,
                                                 pause: { _ in },
                                                 progressReportStride: 1)

        let summary = await downloader.run(tiles: makeTiles(count: 40))

        XCTAssertFalse(summary.isComplete)
        XCTAssertTrue(summary.wasBlockedByAuthorization)
        XCTAssertEqual(fetchCount.withLock { $0 }, 1)
    }

    func testRateLimitedRetryAfterIsClampedBeforePausing() async {
        let store = makeStore()
        let recordedPauses = Locked([TimeInterval]())
        let attempts = Locked(0)
        let downloader = OfflineRegionDownloader(
            store: store,
            fetchTile: { _ in
                let attempt = attempts.withLock { count -> Int in
                    count += 1
                    return count
                }
                return attempt == 1
                    ? .failure(.rateLimited(retryAfter: 3600))
                    : .success(Data([1]), etag: nil)
            },
            maxConcurrentFetches: 1,
            pause: { seconds in
                recordedPauses.withLock { $0.append(seconds) }
            },
            progressReportStride: 1)

        let summary = await downloader.run(tiles: makeTiles(count: 1))

        XCTAssertTrue(summary.isComplete)
        // The server asked for an hour; a bulk download slot never waits
        // longer than the clamp.
        XCTAssertEqual(recordedPauses.withLock { $0 }, [30.0])
    }

    func testCancellationStopsBetweenTilesAndKeepsStoredOnes() async {
        let store = makeStore()
        let fetchCount = Locked(0)
        let parentTask = Locked<Task<OfflineRegionDownloader.Summary, Never>?>(nil)
        let downloader = OfflineRegionDownloader(store: store,
                                                 fetchTile: { tile in
                                                     let count = fetchCount.withLock { count -> Int in
                                                         count += 1
                                                         return count
                                                     }
                                                     if count == 3 {
                                                         // The task handle is stored right after the
                                                         // Task starts; wait for it so the cancel can
                                                         // never be skipped by scheduling order.
                                                         while parentTask.withLock({ $0 }) == nil {
                                                             try? await Task.sleep(nanoseconds: 1_000_000)
                                                         }
                                                         parentTask.withLock { $0 }?.cancel()
                                                     }
                                                     return .success(Data([1]), etag: nil)
                                                 },
                                                 maxConcurrentFetches: 1,
                                                 pause: { _ in },
                                                 progressReportStride: 1)

        let tiles = makeTiles(count: 20)
        let task = Task {
            await downloader.run(tiles: tiles)
        }
        parentTask.withLock { $0 = task }
        let summary = await task.value

        XCTAssertFalse(summary.isComplete)
        XCTAssertFalse(summary.wasBlockedByAuthorization)
        XCTAssertEqual(summary.progress.storedTileCount, 3)
        XCTAssertLessThan(fetchCount.withLock { $0 }, 20)
        XCTAssertTrue(store.containsTile(Tile(x: 0, y: 0, z: 10)))
    }

    func testProgressReportsGrowMonotonically() async {
        let store = makeStore()
        let reports = Locked([OfflineRegionDownloader.Progress]())
        let downloader = makeDownloader(store: store,
                                        fetchTile: { _ in .success(Data([1]), etag: nil) },
                                        onProgress: { progress in
                                            reports.withLock { $0.append(progress) }
                                        })

        _ = await downloader.run(tiles: makeTiles(count: 8))

        let processedCounts = reports.withLock { $0 }.map(\.processedTileCount)
        XCTAssertFalse(processedCounts.isEmpty)
        XCTAssertEqual(processedCounts, processedCounts.sorted())
        XCTAssertEqual(processedCounts.last, 8)
    }
}
