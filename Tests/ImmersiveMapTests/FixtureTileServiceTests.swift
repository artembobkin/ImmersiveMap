// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Foundation
import XCTest

/// The suite renders from pre-loaded tiles, never from the tile service.
///
/// Two halves, and both are needed. The first says the fixture service is
/// really there and really serves a tile the loader can read, so a case that
/// asks for a map with ground on it gets one. The second says no case reaches
/// past it: a test that builds a live runtime out of `ImmersiveMapSettings`
/// as shipped is pointed at `tiles.immersivemap.dev`, and the failure that
/// causes turns up later, somewhere else, as a flake nobody can reproduce.
final class FixtureTileServiceTests: XCTestCase {
    // MARK: - The service is there

    func testFixtureServiceServesATileTheParserCanRead() async throws {
        let tileBaseURL = try XCTUnwrap(FixtureTileService.shared.tileBaseURL,
                                        "The fixture tile service never came up, so no test can render a tile")

        let (data, response) = try await URLSession.shared.data(from: tileBaseURL.appendingPathComponent("3/4/5.mvt"))

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        // Read back by the engine's own decoder: the fixture is only worth
        // anything if the loader can do with it what it does with a download.
        let decoded = try MvtTileDecoder.decode(data: data)
        XCTAssertEqual(decoded.layers.map(\.name), ["water"])
    }

    /// The loader prefers the versioned TileJSON template and only falls back
    /// to the base path, so the fixture service answers the discovery request
    /// too. Without this the request still stays on loopback, but every
    /// rendering case would exercise the fallback path and never the one the
    /// hosted service actually uses.
    func testFixtureServiceAdvertisesATileJSONTemplate() async throws {
        let tileBaseURL = try XCTUnwrap(FixtureTileService.shared.tileBaseURL)
        let source = ImmersiveMapTileSource.immersiveMapTiles(tileBaseURL: tileBaseURL)
        let tileJSONURL = try XCTUnwrap(source.tileJSONURL)

        let template = try await TileJSONTemplateLoader().loadTemplate(from: tileJSONURL)

        let resolved = try XCTUnwrap(TileJSONTileURLProvider.url(fromTemplate: try XCTUnwrap(template),
                                                                 x: 4, y: 5, z: 3,
                                                                 queryItems: []))
        XCTAssertEqual(resolved.host, "127.0.0.1")
        let (data, _) = try await URLSession.shared.data(from: resolved)
        XCTAssertEqual(try MvtTileDecoder.decode(data: data).layers.map(\.name), ["water"],
                       "The advertised template must serve tiles, not just resolve")
    }

    /// The settings a case renders under carry no address that leaves the
    /// machine, whichever helper it took them from.
    func testFixtureSettingsStayOnLoopback() {
        for (label, settings) in [("served", FixtureTiles.settings()),
                                  ("tileless", FixtureTiles.tilelessSettings())] {
            XCTAssertEqual(settings.tiles.network.tileBaseURL.host, "127.0.0.1", "\(label) tile base URL")
            XCTAssertEqual(settings.tiles.network.tileJSONURL?.host, "127.0.0.1", "\(label) TileJSON URL")
            // A run must leave nothing behind in the user's caches, and must
            // not be able to read what an earlier run wrote.
            XCTAssertFalse(settings.tiles.cache.urlCacheEnabled, "\(label) raw tile cache")
            XCTAssertFalse(settings.tiles.cache.preparedTileCacheEnabled, "\(label) prepared tile cache")
        }
    }

    // MARK: - Nothing reaches past it

    /// Every test source that builds a live runtime must take its settings
    /// from `FixtureTiles`.
    ///
    /// Read off the checkout, in the spirit of the cases that assert on shader
    /// source: there is no way to ask a built test bundle which settings its
    /// sources pass. On a device there is no checkout, so this skips.
    func testNoTestBuildsARuntimeFromTheShippedDefaults() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        guard let enumerator = FileManager.default.enumerator(at: testsDirectory,
                                                              includingPropertiesForKeys: nil) else {
            throw XCTSkip("The test sources are not on disk in this environment")
        }

        var offenders: [String] = []
        var scannedFiles = 0
        var runtimeFiles = 0
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            scannedFiles += 1
            // Support owns the fixture layer itself and the harness that
            // rewrites settings before the engine sees them; this file spells
            // the patterns out and would otherwise report itself.
            guard fileURL.deletingLastPathComponent().lastPathComponent != "Support",
                  fileURL.lastPathComponent != URL(fileURLWithPath: #filePath).lastPathComponent else {
                continue
            }
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            guard Self.runtimeEntryPoints.contains(where: source.contains) else {
                continue
            }
            runtimeFiles += 1
            for (index, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where Self.buildsSettingsFromTheShippedDefaults(line) {
                offenders.append("\(fileURL.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        // Nothing on disk means this is running somewhere without the
        // checkout (a device), which is a skip and not a pass. Sources but no
        // runtime among them means the entry-point list went stale and the
        // check has quietly stopped checking anything.
        try XCTSkipIf(scannedFiles == 0, "The test sources are not on disk in this environment")
        XCTAssertGreaterThan(runtimeFiles, 0,
                             "No test builds a runtime any more: FixtureTileServiceTests.runtimeEntryPoints is out of date")
        XCTAssertEqual(offenders, [],
                       """
                       These build a map runtime from the shipped defaults, which streams tiles \
                       from the hosted service. Take the settings from FixtureTiles.settings() \
                       (pre-loaded tiles) or FixtureTiles.tilelessSettings() (no tiles at all).
                       """)
    }

    /// Entry points that take settings verbatim and build a renderer, a tile
    /// loader and a transport out of them.
    private static let runtimeEntryPoints = ["ImmersiveMapNSView(",
                                             "ImmersiveMapUIView(",
                                             "ImmersiveMapStillRecorder(",
                                             "ImmersiveMapTourVideoRecorder(",
                                             "ImmersiveMapVideoExportAttachContext("]

    /// How the shipped defaults are spelled where they are handed to one.
    private static let defaultSettings = ["ImmersiveMapSettings.default",
                                          "settings: .default",
                                          "currentSettings: { .default }"]

    /// Whether the line turns the shipped defaults into settings a runtime
    /// could be built from, and does so without going through `FixtureTiles`.
    ///
    /// `ImmersiveMapSettings.default.presentation` reads one block out of the
    /// defaults for a piece of arithmetic and never reaches a transport;
    /// `ImmersiveMapSettings.default.debugPanel(true)` is whole settings with
    /// the hosted tile service still in them. Textually the two differ by the
    /// call parentheses, which is what this looks for.
    private static func buildsSettingsFromTheShippedDefaults(_ line: Substring) -> Bool {
        guard line.contains("FixtureTiles.") == false else {
            return false
        }
        for marker in defaultSettings {
            for range in line.ranges(of: marker) where isSettingsValue(line[range.upperBound...]) {
                return true
            }
        }
        return false
    }

    /// True unless what follows the defaults is a plain property access.
    private static func isSettingsValue(_ rest: Substring) -> Bool {
        guard rest.first == "." else {
            return true
        }
        let member = rest.dropFirst().prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return rest.dropFirst().dropFirst(member.count).first == "("
    }
}
