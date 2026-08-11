// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import XCTest
@testable import ImmersiveMap

/// The offline modes at the pipeline's download seam: `.offlineOnly` serves
/// from the store without a transport, `.automatic` prefers fresh network
/// bytes and falls back to the store on any failure, `.disabled` ignores the
/// store entirely.
final class DefaultTileLoadPipelineOfflineTests: XCTestCase {
    private var baseDirectory: URL!

    override func setUpWithError() throws {
        baseDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DefaultTileLoadPipelineOffline-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: baseDirectory)
    }

    private struct FixedTileURLProvider: GetMapTileDownloadUrl {
        func get(tileX: Int, tileY: Int, tileZ: Int) -> URL {
            URL(string: "https://tiles.invalid/\(tileZ)/\(tileX)/\(tileY).mvt")!
        }
    }

    private final class ScriptedTileDownloader: TileDownloader {
        let result: DownloadResult

        init(result: DownloadResult) {
            self.result = result
            super.init(mapTileDownloader: FixedTileURLProvider(),
                       session: URLSession(configuration: .ephemeral),
                       authorizationToken: nil)
        }

        override func downloadResult(tile: Tile) async -> DownloadResult {
            result
        }
    }

    private func makeStore() -> OfflineTileStore {
        OfflineTileStore(network: ImmersiveMapSettings.default.tiles.network,
                         baseDirectory: baseDirectory)
    }

    private func makePipeline(downloader: TileDownloader?,
                              store: OfflineTileStore?,
                              mode: ImmersiveMapSettings.TileSettings.OfflineSettings.Mode) -> DefaultTileLoadPipeline {
        DefaultTileLoadPipeline(tileRenderStore: nil,
                                preparedTileDiskCaching: nil,
                                tileDownloader: downloader,
                                offlineTileStore: store,
                                offlineMode: mode)
    }

    func testOfflineOnlyServesStoredBytesWithoutATransport() async throws {
        let store = makeStore()
        let tile = Tile(x: 5, y: 6, z: 7)
        try store.writeTile(tile, data: Data([1, 2, 3]))
        let pipeline = makePipeline(downloader: nil, store: store, mode: .offlineOnly)

        let hit = await pipeline.download(tile: tile)
        XCTAssertEqual(hit, .success(Data([1, 2, 3]), etag: nil))

        let miss = await pipeline.download(tile: Tile(x: 0, y: 0, z: 7))
        XCTAssertEqual(miss, .failure(.network))
    }

    func testOfflineOnlyReportsKnownEmptyTilesAsNotFound() async throws {
        let store = makeStore()
        let tile = Tile(x: 5, y: 6, z: 7)
        try store.writeEmptyTileMarker(tile)
        let pipeline = makePipeline(downloader: nil, store: store, mode: .offlineOnly)

        let result = await pipeline.download(tile: tile)
        XCTAssertEqual(result, .failure(.notFound))
    }

    func testAutomaticFallsBackToTheStoreOnNetworkFailure() async throws {
        let store = makeStore()
        let tile = Tile(x: 5, y: 6, z: 7)
        try store.writeTile(tile, data: Data([9, 9]))
        let pipeline = makePipeline(downloader: ScriptedTileDownloader(result: .failure(.network)),
                                    store: store,
                                    mode: .automatic)

        let fallback = await pipeline.download(tile: tile)
        XCTAssertEqual(fallback, .success(Data([9, 9]), etag: nil))

        let miss = await pipeline.download(tile: Tile(x: 0, y: 0, z: 7))
        XCTAssertEqual(miss, .failure(.network))
    }

    func testAutomaticPrefersFreshNetworkBytesOverTheStore() async throws {
        let store = makeStore()
        let tile = Tile(x: 5, y: 6, z: 7)
        try store.writeTile(tile, data: Data([9, 9]))
        let pipeline = makePipeline(downloader: ScriptedTileDownloader(result: .success(Data([1]), etag: "fresh")),
                                    store: store,
                                    mode: .automatic)

        let result = await pipeline.download(tile: tile)
        XCTAssertEqual(result, .success(Data([1]), etag: "fresh"))
    }

    func testDisabledIgnoresTheStore() async throws {
        let store = makeStore()
        let tile = Tile(x: 5, y: 6, z: 7)
        try store.writeTile(tile, data: Data([9, 9]))
        let pipeline = makePipeline(downloader: ScriptedTileDownloader(result: .failure(.network)),
                                    store: nil,
                                    mode: .disabled)

        let result = await pipeline.download(tile: tile)
        XCTAssertEqual(result, .failure(.network))
    }
}
