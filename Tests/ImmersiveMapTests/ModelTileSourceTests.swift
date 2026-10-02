// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
@testable import ImmersiveMap
import PMTiles
import PMTilesTestSupport
import XCTest

/// The model tile source: a tile comes from the archive once and from the
/// disk after that. The archive is a file on disk here, read by the same
/// client that reads a remote one, so nothing reaches a network.
final class ModelTileSourceTests: XCTestCase {
    private static let tile = Tile(x: 9904, y: 5121, z: 14)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelTileSourceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes an archive holding one model tile and returns its URL.
    private func writeArchive(tileType: PMTilesTileType = .unknown,
                              name: String = "models.pmtiles") throws -> (url: URL, tileData: Data) {
        let tileData = ModelTileFixture().serialized()
        var writer = PMTilesArchiveWriter()
        writer.tiles = [.init(z: Self.tile.z, x: Self.tile.x, y: Self.tile.y, data: tileData)]
        writer.tileType = tileType
        writer.minZoom = 14
        writer.maxZoom = 14
        let url = directory.appendingPathComponent(name)
        try writer.serializedData().write(to: url)
        return (url, tileData)
    }

    private func makeSource(archiveURL: URL,
                            diskCacheSizeInBytes: Int = 1 << 20,
                            clearsDiskCache: Bool = false) -> ModelTileSource {
        ModelTileSource(archive: PMTilesArchiveClient(archiveURL: archiveURL,
                                                      requestHeaders: [:],
                                                      session: URLSession(configuration: .ephemeral),
                                                      tileType: .unknown),
                        diskCacheSizeInBytes: diskCacheSizeInBytes,
                        clearsDiskCache: clearsDiskCache,
                        baseCachesDirectory: directory.appendingPathComponent("Caches"))
    }

    func testATileComesFromTheArchiveAndIsKeptOnDisk() async throws {
        let archive = try writeArchive()
        let source = makeSource(archiveURL: archive.url)

        let outcome = try await source.tileBytes(Self.tile)
        XCTAssertEqual(outcome, .tile(archive.tileData, fileURL: nil),
                       "a tile fresh from the archive is in memory, and goes to the GPU from there")
        XCTAssertEqual(try Data(contentsOf: source.cacheFileURL(for: Self.tile)), archive.tileData,
                       "the disk keeps the tile decompressed, as the GPU takes it")
    }

    func testATileTheArchiveDoesNotHoldIsMissing() async throws {
        let source = makeSource(archiveURL: try writeArchive().url)

        let neighbour = try await source.tileBytes(Tile(x: 9905, y: 5121, z: 14))
        XCTAssertEqual(neighbour, .missing)
        let otherZoom = try await source.tileBytes(Tile(x: 4952, y: 2560, z: 13))
        XCTAssertEqual(otherZoom, .missing)
    }

    /// A tile seen before needs no archive: with the archive gone, a new
    /// source of the same URL still answers it from the disk.
    func testACachedTileIsAnsweredWithoutTheArchive() async throws {
        let archive = try writeArchive()
        _ = try await makeSource(archiveURL: archive.url).tileBytes(Self.tile)
        try FileManager.default.removeItem(at: archive.url)

        let source = makeSource(archiveURL: archive.url)
        let outcome = try await source.tileBytes(Self.tile)
        XCTAssertEqual(outcome, .tile(archive.tileData, fileURL: source.cacheFileURL(for: Self.tile)),
                       "a tile from the disk comes with its file, which the GPU's blocks are loaded from")
    }

    /// The cache belongs to an archive's URL: another archive does not
    /// read its tiles.
    func testAnotherArchiveDoesNotReadThisOnesCache() async throws {
        let first = try writeArchive(name: "models-1.pmtiles")
        _ = try await makeSource(archiveURL: first.url).tileBytes(Self.tile)

        let second = makeSource(archiveURL: directory.appendingPathComponent("models-2.pmtiles"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.cacheFileURL(for: Self.tile).path))
    }

    func testClearingTheDiskCacheRemovesTheKeptTiles() async throws {
        let archive = try writeArchive()
        let source = makeSource(archiveURL: archive.url)
        _ = try await source.tileBytes(Self.tile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.cacheFileURL(for: Self.tile).path))

        let cleared = makeSource(archiveURL: archive.url, clearsDiskCache: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleared.cacheFileURL(for: Self.tile).path))
    }

    func testADiscardedTileIsReadFromTheArchiveAgain() async throws {
        let archive = try writeArchive()
        let source = makeSource(archiveURL: archive.url)
        _ = try await source.tileBytes(Self.tile)
        try Data("not a tile".utf8).write(to: source.cacheFileURL(for: Self.tile))

        source.discardCachedTile(Self.tile)
        let outcome = try await source.tileBytes(Self.tile)
        XCTAssertEqual(outcome, .tile(archive.tileData, fileURL: nil))
    }

    // MARK: - One name, uploaded again

    /// A host that answers range requests from whatever archive it holds
    /// now, under the ETag it gives that upload, or not at all.
    private final class ScriptedHost: @unchecked Sendable {
        let upload = Locked<(archive: Data, etag: String)>((Data(), ""))
        let isReachable = Locked(true)

        func client() -> PMTilesArchiveClient {
            let upload = self.upload
            let isReachable = self.isReachable
            return PMTilesArchiveClient(archiveURL: URL(string: "https://tiles.example.com/models.pmtiles")!,
                                        requestHeaders: [:],
                                        tileType: .unknown) { range, _ in
                guard isReachable.withLock({ $0 }) else {
                    throw PMTilesArchiveClient.Failure.network("unreachable")
                }
                let (archive, etag) = upload.withLock { $0 }
                let end = min(Int(range.upperBound), archive.count)
                let body = Int(range.lowerBound) < end ? archive.subdata(in: Int(range.lowerBound)..<end) : Data()
                return PMTilesArchiveClient.RangeResponse(statusCode: 206, headers: ["ETag": etag], body: body)
            }
        }
    }

    private func archive(holding model: String) -> (archive: Data, tileData: Data) {
        var fixture = ModelTileFixture()
        fixture.models = [ModelTileFixture.Model(id: model)]
        let tileData = fixture.serialized()
        var writer = PMTilesArchiveWriter()
        writer.tiles = [.init(z: Self.tile.z, x: Self.tile.x, y: Self.tile.y, data: tileData)]
        writer.tileType = .unknown
        writer.minZoom = 14
        writer.maxZoom = 14
        return (writer.serializedData(), tileData)
    }

    private func makeSource(host: ScriptedHost) -> ModelTileSource {
        ModelTileSource(archive: host.client(),
                        diskCacheSizeInBytes: 1 << 20,
                        clearsDiskCache: false,
                        baseCachesDirectory: directory.appendingPathComponent("Caches"))
    }

    /// Waits for the source's housekeeping, which runs off the caller's
    /// thread, to reach a state.
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while condition() == false {
            guard Date() < deadline else {
                return XCTFail("The source's housekeeping did not finish")
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// An archive published under one fixed name is overwritten by the next
    /// bake. The tiles kept on disk are the old upload's: the new ETag
    /// leaves them behind, and the map shows the new models.
    func testAnArchiveUploadedAgainUnderTheSameNameIsReadAgain() async throws {
        let host = ScriptedHost()
        let first = archive(holding: "first-bake")
        host.upload.withLock { $0 = (first.archive, "\"etag-1\"") }
        let firstSource = makeSource(host: host)
        let firstOutcome = try await firstSource.tileBytes(Self.tile)
        XCTAssertEqual(firstOutcome, .tile(first.tileData, fileURL: nil))
        let firstFile = firstSource.cacheFileURL(for: Self.tile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstFile.path))

        let second = archive(holding: "second-bake")
        host.upload.withLock { $0 = (second.archive, "\"etag-2\"") }
        let secondSource = makeSource(host: host)
        let secondOutcome = try await secondSource.tileBytes(Self.tile)
        XCTAssertEqual(secondOutcome, .tile(second.tileData, fileURL: nil), "the old upload's tile on disk must not answer")
        XCTAssertNotEqual(secondSource.cacheFileURL(for: Self.tile), firstFile)

        try await waitUntil { FileManager.default.fileExists(atPath: firstFile.path) == false }
    }

    /// With no network the ETag cannot be asked for: the upload seen last
    /// stands, and its tiles on disk still serve.
    func testWithoutANetworkTheLastUploadSeenStillServes() async throws {
        let host = ScriptedHost()
        let bake = archive(holding: "bake")
        host.upload.withLock { $0 = (bake.archive, "\"etag-1\"") }
        let online = makeSource(host: host)
        _ = try await online.tileBytes(Self.tile)
        let remembered = online.cacheFileURL(for: Self.tile)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(ModelTileSource.currentVersionFileName)
        try await waitUntil { FileManager.default.fileExists(atPath: remembered.path) }

        host.isReachable.withLock { $0 = false }
        let offline = makeSource(host: host)
        let outcome = try await offline.tileBytes(Self.tile)
        XCTAssertEqual(outcome, .tile(bake.tileData, fileURL: offline.cacheFileURL(for: Self.tile)))

        do {
            _ = try await offline.tileBytes(Tile(x: 9905, y: 5121, z: 14))
            XCTFail("a tile that is not on disk needs the archive")
        } catch {}
    }

    func testEachUploadHasADirectoryOfItsOwn() {
        XCTAssertNotEqual(ModelTileSource.versionName(of: "\"etag-1\""), ModelTileSource.versionName(of: "\"etag-2\""))
        XCTAssertEqual(ModelTileSource.versionName(of: "\"etag-1\""), ModelTileSource.versionName(of: "\"etag-1\""))
        XCTAssertEqual(ModelTileSource.versionName(of: nil), ModelTileSource.unversionedName)
        XCTAssertEqual(ModelTileSource.versionName(of: ""), ModelTileSource.unversionedName)
    }

    /// The map's own archive is not an archive of models: pointing the
    /// model archive at it is an error to report, not tiles to draw.
    func testAnArchiveOfMapTilesIsNotRead() async throws {
        let source = makeSource(archiveURL: try writeArchive(tileType: .mvt).url)

        do {
            _ = try await source.tileBytes(Self.tile)
            XCTFail("an archive of map tiles was read as models")
        } catch let failure as PMTilesArchiveClient.Failure {
            guard case .archiveUnreadable = failure else {
                return XCTFail("expected an unreadable archive, got \(failure)")
            }
        }
    }

    /// The quota trims the least recently read tiles first.
    func testTrimmingRemovesTheLeastRecentlyReadFirst() throws {
        let cache = directory.appendingPathComponent("trim")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        for (index, name) in ["old", "middle", "new"].enumerated() {
            let url = cache.appendingPathComponent("\(name).immt")
            try Data(repeating: 1, count: 1000).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000 + Double(index) * 1000)],
                                                  ofItemAtPath: url.path)
        }

        ModelTileSource.trim(directory: cache, toByteCount: 2500)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path).sorted(),
                       ["middle.immt", "new.immt"])

        ModelTileSource.trim(directory: cache, toByteCount: 2500)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path).count, 2,
                       "inside the quota nothing goes")
    }
}
