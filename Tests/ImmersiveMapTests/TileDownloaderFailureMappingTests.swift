// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
@testable import ImmersiveMap
import PMTiles
import PMTilesTestSupport
import XCTest

/// The archive client's answers in the loader's download vocabulary.
///
/// Most of the table is the old status mapping, unchanged. The one new
/// distinction is that a 404 on the archive is not a 404 on a tile: the first
/// must back off and retry, the second is remembered as empty for a long
/// while. Confusing them would put a whole planet in the not-found cooldown,
/// and make an offline region download write empty markers for every tile,
/// because the file was missing for a minute.
final class TileDownloaderFailureMappingTests: XCTestCase {
    private static func downloader(_ response: @escaping @Sendable (Range<UInt64>) -> PMTilesArchiveClient.RangeResponse) -> TileDownloader {
        TileDownloader(archive: PMTilesArchiveClient(archiveURL: URL(string: "https://tiles.example.com/planet.pmtiles")!,
                                                     requestHeaders: [:],
                                                     fetchRange: { range, _ in response(range) }))
    }

    private static func status(_ code: Int, headers: [String: String] = [:], body: Data = Data()) -> TileDownloader {
        downloader { _ in .init(statusCode: code, headers: headers, body: body) }
    }

    private static func archiveDownloader(tiles: [PMTilesArchiveWriter.Tile]) -> TileDownloader {
        var writer = PMTilesArchiveWriter()
        writer.tiles = tiles
        writer.maxZoom = 10
        let archive = writer.serializedData()
        return downloader { range in
            let end = min(Int(range.upperBound), archive.count)
            return .init(statusCode: 206,
                         headers: ["Content-Range": "bytes \(range.lowerBound)-\(end - 1)/\(archive.count)",
                                   "ETag": "\"planet\""],
                         body: archive.subdata(in: Int(range.lowerBound)..<end))
        }
    }

    override func setUp() {
        super.setUp()
        TileNoticeThrottle.rateLimit.reset()
        TileNoticeThrottle.authorization.reset()
        TileNoticeThrottle.archiveDepth.reset()
        TileNoticeThrottle.archiveUnreadable.reset()
    }

    func testATileIsASuccessWithTheArchiveETag() async {
        let bytes = Data([1, 2, 3])
        let downloader = Self.archiveDownloader(tiles: [.init(z: 3, x: 4, y: 5, data: bytes)])

        let result = await downloader.downloadResult(tile: Tile(x: 4, y: 5, z: 3))

        guard case let .success(data, etag) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(data, bytes)
        XCTAssertEqual(etag, "\"planet\"/\(PMTilesTileID.id(z: 3, x: 4, y: 5)!)")
    }

    func testATileTheArchiveDoesNotHoldIsNotFound() async {
        let downloader = Self.archiveDownloader(tiles: [.init(z: 3, x: 4, y: 5, data: Data([1]))])

        let result = await downloader.downloadResult(tile: Tile(x: 0, y: 0, z: 3))

        XCTAssertEqual(result, .failure(.notFound))
    }

    func testATileOutsideTheArchiveDepthIsNotFound() async {
        let downloader = Self.archiveDownloader(tiles: [.init(z: 3, x: 4, y: 5, data: Data([1]))])

        let result = await downloader.downloadResult(tile: Tile(x: 0, y: 0, z: 11))

        XCTAssertEqual(result, .failure(.notFound))
    }

    func testAnEmptyTileIsAnEmptyBody() async {
        let downloader = Self.archiveDownloader(tiles: [.init(z: 3, x: 4, y: 5, data: Data())])

        let result = await downloader.downloadResult(tile: Tile(x: 4, y: 5, z: 3))

        XCTAssertEqual(result, .failure(.emptyBody))
    }

    func testAMissingArchiveIsArchiveUnavailableNeverNotFound() async {
        for code in [404, 410] {
            let result = await Self.status(code).downloadResult(tile: Tile(x: 4, y: 5, z: 3))
            XCTAssertEqual(result, .failure(.archiveUnavailable), "HTTP \(code) on the archive")
        }
    }

    func testBytesThatAreNotAnArchiveAreArchiveUnavailable() async {
        let downloader = Self.status(206, body: Data(repeating: 0x41, count: 200))

        let result = await downloader.downloadResult(tile: Tile(x: 4, y: 5, z: 3))

        XCTAssertEqual(result, .failure(.archiveUnavailable))
    }

    func testTheStatusMappingIsUnchangedForEverythingElse() async {
        let cases: [(Int, TileDownloader.DownloadFailure)] = [
            (401, .unauthorized),
            (403, .forbidden),
            (429, .rateLimited(retryAfter: 7)),
            (500, .server(statusCode: 500)),
            (503, .server(statusCode: 503)),
            (418, .client(statusCode: 418)),
        ]
        for (code, expected) in cases {
            let result = await Self.status(code, headers: ["Retry-After": "7"]).downloadResult(tile: Tile(x: 4, y: 5, z: 3))
            XCTAssertEqual(result, .failure(expected), "HTTP \(code)")
        }
    }

    func testATransportFailureIsNetwork() async {
        let downloader = TileDownloader(archive: PMTilesArchiveClient(archiveURL: URL(string: "https://tiles.example.com/planet.pmtiles")!,
                                                                      requestHeaders: [:],
                                                                      fetchRange: { _, _ in
                                                                          throw PMTilesArchiveClient.Failure.network("timed out")
                                                                      }))

        let result = await downloader.downloadResult(tile: Tile(x: 4, y: 5, z: 3))

        XCTAssertEqual(result, .failure(.network))
    }

    /// The retry controller treats the new case like a server error: per-tile
    /// backoff, no global cooldown.
    func testArchiveUnavailableBacksOffLikeAServerError() {
        let now = Date()
        let controller = TileRetryController(policy: .default, now: { now })
        let tile = Tile(x: 4, y: 5, z: 3)

        controller.registerFailure(for: tile, reason: .download(.archiveUnavailable))

        XCTAssertTrue(controller.shouldBlock(tile: tile))
        XCTAssertFalse(controller.shouldBlock(tile: Tile(x: 0, y: 0, z: 0)),
                       "another tile is not blocked globally")
        XCTAssertEqual(controller.earliestNextRetryDate(),
                       now.addingTimeInterval(TileRetryController.Policy.default.baseBackoff),
                       "the first retry is the base backoff, not the not-found cooldown")
    }
}
