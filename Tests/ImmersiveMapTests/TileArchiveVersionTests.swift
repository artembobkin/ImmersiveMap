// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
@testable import ImmersiveMap
import PMTiles
import XCTest

/// Which upload of the tile archive the prepared tiles on disk must be of:
/// what lets an archive be overwritten under one URL without the map going
/// on showing the tiles of the old one.
final class TileArchiveVersionTests: XCTestCase {
    private static let tile = Tile(x: 9904, y: 5121, z: 14)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TileArchiveVersionTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeVersion(sourceRevision: UInt64 = 7, clearsRemembered: Bool = false) -> TileArchiveVersion {
        TileArchiveVersion(sourceRevision: sourceRevision,
                           clearsRemembered: clearsRemembered,
                           baseCachesDirectory: directory)
    }

    private func sourceETag(_ archiveETag: String, _ tile: Tile = TileArchiveVersionTests.tile) throws -> String {
        "\(archiveETag)/\(try XCTUnwrap(PMTilesTileID.id(z: tile.z, x: tile.x, y: tile.y)))"
    }

    /// Before the archive has said anything, any entry answers: a first
    /// launch must not turn away what it has no way to judge.
    func testAnUnknownArchiveAcceptsAnyEntry() {
        XCTAssertNil(makeVersion().expectedSourceETag(for: Self.tile))
    }

    /// The expected ETag is the one the downloader states for a tile, the
    /// archive's and the tile's id, so an entry saved under this upload
    /// matches and one saved under another does not.
    func testAKnownArchiveExpectsItsOwnEntries() throws {
        let version = makeVersion()
        version.observe(archiveETag: "\"upload-1\"")

        XCTAssertEqual(version.expectedSourceETag(for: Self.tile), try sourceETag("\"upload-1\""))
        XCTAssertNotEqual(version.expectedSourceETag(for: Self.tile), try sourceETag("\"upload-2\""))
        XCTAssertNotEqual(version.expectedSourceETag(for: Tile(x: 9905, y: 5121, z: 14)),
                          version.expectedSourceETag(for: Self.tile))
    }

    /// Every downloaded tile confirms the upload, or reports a new one.
    func testADownloadedTileSaysWhichUploadTheArchiveIs() throws {
        let version = makeVersion()
        version.observe(sourceETag: try sourceETag("\"upload-1\""))
        XCTAssertEqual(version.expectedSourceETag(for: Self.tile), try sourceETag("\"upload-1\""))

        version.observe(sourceETag: try sourceETag("\"upload-2\"", Tile(x: 1, y: 2, z: 3)))
        XCTAssertEqual(version.expectedSourceETag(for: Self.tile), try sourceETag("\"upload-2\""),
                       "an archive uploaded again leaves the old entries behind")
    }

    /// A host that sends no ETag is not checked, as before: the downloader
    /// states such a tile with a dash for the archive.
    func testAHostWithoutAnETagIsNotChecked() throws {
        let version = makeVersion()
        version.observe(archiveETag: "\"upload-1\"")
        version.observe(sourceETag: "-/42")
        XCTAssertNil(version.expectedSourceETag(for: Self.tile))

        version.observe(archiveETag: nil)
        XCTAssertNil(version.expectedSourceETag(for: Self.tile))
    }

    /// A tile served with no source ETag (from an offline region) says
    /// nothing about the archive.
    func testATileWithoutASourceETagChangesNothing() throws {
        let version = makeVersion()
        version.observe(archiveETag: "\"upload-1\"")
        version.observe(sourceETag: nil)
        version.observe(sourceETag: "no separator")

        XCTAssertEqual(version.expectedSourceETag(for: Self.tile), try sourceETag("\"upload-1\""))
    }

    /// While the archive cannot be reached, an entry of an older upload is
    /// better than no tile. The check comes back with the network.
    func testAnUnreachableArchiveAcceptsAnyEntryUntilItAnswersAgain() throws {
        let version = makeVersion()
        version.observe(archiveETag: "\"upload-2\"")
        version.observeUnreachable()
        XCTAssertNil(version.expectedSourceETag(for: Self.tile))

        version.observe(sourceETag: try sourceETag("\"upload-2\""))
        XCTAssertEqual(version.expectedSourceETag(for: Self.tile), try sourceETag("\"upload-2\""))
    }

    /// The ETag seen last is kept on disk, so the next session checks its
    /// entries from the first tile, with no request, and separately for
    /// each archive.
    func testTheLastETagSeenIsRememberedForTheNextSession() async throws {
        makeVersion().observe(archiveETag: "\"upload-1\"")
        let file = directory.appendingPathComponent(TileArchiveVersion.directoryName).appendingPathComponent("7")
        let deadline = Date().addingTimeInterval(10)
        while FileManager.default.fileExists(atPath: file.path) == false {
            guard Date() < deadline else { return XCTFail("The ETag was not written") }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(makeVersion().expectedSourceETag(for: Self.tile), try sourceETag("\"upload-1\""))
        XCTAssertNil(makeVersion(sourceRevision: 8).expectedSourceETag(for: Self.tile),
                     "another archive has not been seen")
        XCTAssertNil(makeVersion(clearsRemembered: true).expectedSourceETag(for: Self.tile),
                     "a map that clears its caches starts over")
    }

    /// One header request a session, however many tiles ask.
    func testTheSessionCheckStartsOnce() {
        let version = makeVersion()
        XCTAssertTrue(version.beginSessionCheck())
        XCTAssertFalse(version.beginSessionCheck())
    }
}
