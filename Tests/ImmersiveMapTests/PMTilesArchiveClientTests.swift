// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
@testable import ImmersiveMap
import Mvt
import PMTiles
import PMTilesTestSupport
import XCTest

/// The archive client over a loopback host that behaves like a static file
/// server: range requests, ETags, and the two ways a host can surprise it
/// (the file replaced under it, the range ignored).
final class PMTilesArchiveClientTests: XCTestCase {
    /// A server whose resource can be swapped mid-run, with every request it
    /// saw kept for the assertions.
    private final class ScriptedHost: @unchecked Sendable {
        let resource: Locked<LocalTileServer.Resource?>
        let requests = Locked<[LocalTileServer.Request]>([])
        let server: LocalTileServer
        let archiveURL: URL

        init(_ initial: LocalTileServer.Resource?) throws {
            let resource = Locked<LocalTileServer.Resource?>(initial)
            self.resource = resource
            let requests = self.requests
            server = try LocalTileServer(route: { request in
                requests.withLock { $0.append(request) }
                return resource.withLock { $0 }
            })
            archiveURL = try XCTUnwrap(server.archiveURL, "The loopback server never came up")
        }

        var requestCount: Int {
            requests.withLock { $0.count }
        }

        func client(headers: [String: String] = [:]) -> PMTilesArchiveClient {
            PMTilesArchiveClient(archiveURL: archiveURL,
                                 requestHeaders: headers,
                                 session: URLSession(configuration: .ephemeral))
        }
    }

    private static func tile(_ z: Int, _ x: Int, _ y: Int, name: String) -> PMTilesArchiveWriter.Tile {
        .init(z: z, x: x, y: y, data: VectorTileFixture.fullCoverageTile(layerName: name))
    }

    /// A small archive with a handful of distinct tiles.
    private static func makeArchive(maximumRootEntries: Int = 16_384,
                                    tileCompression: PMTilesCompression = .gzip) -> Data {
        var writer = PMTilesArchiveWriter()
        writer.tiles = [
            tile(0, 0, 0, name: "root"),
            tile(3, 4, 5, name: "water"),
            tile(3, 4, 6, name: "landuse"),
            tile(7, 66, 41, name: "deep"),
        ]
        writer.tileCompression = tileCompression
        writer.maximumRootEntries = maximumRootEntries
        writer.maxZoom = 12
        return writer.serializedData()
    }

    private static func layerNames(_ outcome: PMTilesArchiveClient.Outcome) throws -> [String] {
        guard case let .tile(data, _) = outcome else {
            XCTFail("expected a tile, got \(outcome)")
            return []
        }
        return try MvtTileDecoder.decode(data: data).layers.map(\.name)
    }

    // MARK: - Reading

    func testAGzipTileComesBackDecodedForTheParser() async throws {
        let host = try ScriptedHost(.archive(Self.makeArchive()))
        let client = host.client()

        let outcome = try await client.tileBytes(z: 3, x: 4, y: 5)

        XCTAssertEqual(try Self.layerNames(outcome), ["water"])
    }

    func testAnUncompressedArchiveReadsTheSame() async throws {
        let host = try ScriptedHost(.archive(Self.makeArchive(tileCompression: .none)))
        let client = host.client()

        let outcome = try await client.tileBytes(z: 3, x: 4, y: 6)

        XCTAssertEqual(try Self.layerNames(outcome), ["landuse"])
    }

    func testATileTheArchiveDoesNotHoldIsMissingAndOneOutsideItsDepthIsSaidSo() async throws {
        let host = try ScriptedHost(.archive(Self.makeArchive()))
        let client = host.client()

        let missing = try await client.tileBytes(z: 3, x: 0, y: 0)
        XCTAssertEqual(missing, PMTilesArchiveClient.Outcome.missing)

        let tooDeep = try await client.tileBytes(z: 13, x: 0, y: 0)
        XCTAssertEqual(tooDeep, PMTilesArchiveClient.Outcome.outsideZoomRange)
    }

    /// The archive's validator rides on every tile, so the prepared cache's
    /// ETag-matched reuse can never match a tile of a previous upload.
    func testTheTileETagCarriesTheArchiveValidator() async throws {
        let host = try ScriptedHost(.archive(Self.makeArchive(), etag: "\"planet-1\""))
        let client = host.client()

        guard case let .tile(_, etag) = try await client.tileBytes(z: 3, x: 4, y: 5) else {
            return XCTFail("expected a tile")
        }
        XCTAssertEqual(etag?.hasPrefix("\"planet-1\"/"), true, etag ?? "nil")
    }

    // MARK: - Requests

    /// The header and root directory come in one request, shared by every
    /// lookup that starts while it is in flight. Then one request per tile.
    func testConcurrentLookupsShareOneHeaderRequest() async throws {
        let host = try ScriptedHost(.archive(Self.makeArchive()))
        let client = host.client()

        try await withThrowingTaskGroup(of: PMTilesArchiveClient.Outcome.self) { group in
            for _ in 0..<8 {
                group.addTask { try await client.tileBytes(z: 3, x: 4, y: 5) }
            }
            for try await outcome in group {
                XCTAssertEqual(try Self.layerNames(outcome), ["water"])
            }
        }

        // One index fetch plus one range per tile lookup.
        XCTAssertEqual(host.requestCount, 1 + 8)
        let first = try XCTUnwrap(host.requests.withLock { $0.first })
        XCTAssertEqual(first.header("Range"), "bytes=0-\(PMTilesHeader.initialFetchByteCount - 1)")
    }

    /// With the root forced down to leaf pointers, a leaf is fetched once
    /// and answers every later tile under it from memory.
    func testALeafDirectoryIsFetchedOnceAndThenServedFromTheCache() async throws {
        // Leaves of three entries: the four tiles sort by Hilbert id as
        // z0 (0), z3 4/5 (56), z3 4/6 (57) and the z7 tile, so the first
        // leaf holds both z3 tiles and the second request needs no leaf.
        let host = try ScriptedHost(.archive(Self.makeArchive(maximumRootEntries: 3)))
        let client = host.client()

        let outcome = try await client.tileBytes(z: 3, x: 4, y: 5)

        XCTAssertEqual(try Self.layerNames(outcome), ["water"])
        let afterFirst = host.requestCount
        // Index, leaf, tile.
        XCTAssertEqual(afterFirst, 3)

        let second = try await client.tileBytes(z: 3, x: 4, y: 6)

        XCTAssertEqual(try Self.layerNames(second), ["landuse"])
        // The same leaf: one request, for the tile.
        XCTAssertEqual(host.requestCount, afterFirst + 1)
    }

    func testTheRequestHeadersTravelOnEveryRequest() async throws {
        let host = try ScriptedHost(.archive(Self.makeArchive(maximumRootEntries: 2)))
        let client = host.client(headers: ["Authorization": "Bearer token", "X-Client": "test"])

        _ = try await client.tileBytes(z: 3, x: 4, y: 5)

        let requests = host.requests.withLock { $0 }
        XCTAssertEqual(requests.count, 3)
        for request in requests {
            XCTAssertEqual(request.header("Authorization"), "Bearer token")
            XCTAssertEqual(request.header("X-Client"), "test")
            XCTAssertNotNil(request.header("Range"))
        }
    }

    /// Once the index is known, the client asks for its bytes only under the
    /// ETag it read the index under.
    func testTileRequestsPinTheArchiveWithIfMatch() async throws {
        let host = try ScriptedHost(.archive(Self.makeArchive(), etag: "\"planet-1\""))
        let client = host.client()

        _ = try await client.tileBytes(z: 3, x: 4, y: 5)

        let requests = host.requests.withLock { $0 }
        XCTAssertNil(requests[0].header("If-Match"), "the first request has nothing to match against")
        XCTAssertEqual(requests[1].header("If-Match"), "\"planet-1\"")
    }

    // MARK: - The host surprises the client

    /// The file is replaced between the index and a tile: the host answers
    /// 412 to the pinned request, the client reloads and answers from the
    /// new archive.
    func testAReplacedArchiveIsReloadedOnce() async throws {
        let host = try ScriptedHost(.archive(Self.makeArchive(), etag: "\"planet-1\""))
        let client = host.client()
        let before = try await client.tileBytes(z: 3, x: 4, y: 5)
        XCTAssertEqual(try Self.layerNames(before), ["water"])

        var replaced = PMTilesArchiveWriter()
        replaced.tiles = [Self.tile(3, 4, 5, name: "replaced")]
        replaced.maxZoom = 12
        host.resource.withLock { $0 = .archive(replaced.serializedData(), etag: "\"planet-2\"") }

        let outcome = try await client.tileBytes(z: 3, x: 4, y: 5)

        XCTAssertEqual(try Self.layerNames(outcome), ["replaced"])
        // Refused tile, then index and tile again.
        XCTAssertEqual(host.requestCount, 2 + 3)
    }

    /// A shorter file replaces the archive and the host answers 416 to a
    /// range past its end: the same reload.
    func testARangePastTheEndReloadsTheIndex() async throws {
        let host = try ScriptedHost(.archive(Self.makeArchive(), etag: "\"planet-1\""))
        let client = host.client()
        let before = try await client.tileBytes(z: 7, x: 66, y: 41)
        XCTAssertEqual(try Self.layerNames(before), ["deep"])

        var tiny = PMTilesArchiveWriter()
        tiny.tiles = [Self.tile(0, 0, 0, name: "tiny")]
        tiny.maxZoom = 12
        // The new file keeps the old ETag on purpose, so If-Match passes and
        // only the range itself can tell the client the file changed.
        host.resource.withLock { $0 = .archive(tiny.serializedData(), etag: "\"planet-1\"") }

        let outcome = try await client.tileBytes(z: 7, x: 66, y: 41)

        XCTAssertEqual(outcome, PMTilesArchiveClient.Outcome.missing)
    }

    /// A host that ignores `Range` and sends the whole file: the client
    /// slices what it asked for out of the answer.
    func testAHostThatIgnoresRangesStillYieldsTheTile() async throws {
        var resource = LocalTileServer.Resource.archive(Self.makeArchive())
        resource.ignoresRanges = true
        let host = try ScriptedHost(resource)
        let client = host.client()

        let outcome = try await client.tileBytes(z: 3, x: 4, y: 5)

        XCTAssertEqual(try Self.layerNames(outcome), ["water"])
    }

    // MARK: - Failures

    func testAMissingArchiveIsAnHTTPFailureNotAMissingTile() async throws {
        let host = try ScriptedHost(nil)
        let client = host.client()

        do {
            _ = try await client.tileBytes(z: 3, x: 4, y: 5)
            XCTFail("expected a failure")
        } catch let failure as PMTilesArchiveClient.Failure {
            guard case let .http(statusCode, _, _) = failure else {
                return XCTFail("expected an HTTP failure, got \(failure)")
            }
            XCTAssertEqual(statusCode, 404)
        }
    }

    func testBytesThatAreNotAnArchiveAreUnreadable() async throws {
        let host = try ScriptedHost(.archive(Data(repeating: 0x41, count: 1_000)))
        let client = host.client()

        do {
            _ = try await client.tileBytes(z: 3, x: 4, y: 5)
            XCTFail("expected a failure")
        } catch let failure as PMTilesArchiveClient.Failure {
            guard case .archiveUnreadable = failure else {
                return XCTFail("expected archiveUnreadable, got \(failure)")
            }
        }
    }

    func testADeadPortIsANetworkFailureWithoutTouchingAnythingElse() async throws {
        let client = PMTilesArchiveClient(archiveURL: FixtureTiles.deadEndArchiveURL,
                                          requestHeaders: [:],
                                          session: URLSession(configuration: .ephemeral))

        do {
            _ = try await client.tileBytes(z: 0, x: 0, y: 0)
            XCTFail("expected a failure")
        } catch let failure as PMTilesArchiveClient.Failure {
            guard case .network = failure else {
                return XCTFail("expected a network failure, got \(failure)")
            }
        }
    }
}
