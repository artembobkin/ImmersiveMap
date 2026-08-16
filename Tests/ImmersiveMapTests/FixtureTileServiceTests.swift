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
                                                                 x: 4, y: 5, z: 3))
        XCTAssertEqual(resolved.host, "127.0.0.1")
        let (data, _) = try await URLSession.shared.data(from: resolved)
        XCTAssertEqual(try MvtTileDecoder.decode(data: data).layers.map(\.name), ["water"],
                       "The advertised template must serve tiles, not just resolve")
    }

    /// A request split across two writes is still answered with the tile.
    ///
    /// TCP may break even a short GET in two, and the server used to answer
    /// whatever had arrived by the first read: the truncated path matched no
    /// route and became a 404, which the loader reads as "this tile is empty"
    /// and blacklists for ten minutes (`TileRetryController.notFoundCooldown`).
    /// One split request would have emptied the map for the rest of the run.
    func testASplitRequestIsStillAnsweredWithTheTile() throws {
        let (data, status) = try Self.rawRequest(["GET /tiles/3/4/", "5.mvt HTTP/1.1\r\nHost: fixture\r\n\r\n"])

        XCTAssertEqual(status, 200, "A request that arrived in two pieces must not be a 404")
        XCTAssertEqual(try MvtTileDecoder.decode(data: data).layers.map(\.name), ["water"])
    }

    /// A request that stops mid-line is a 400, deliberately not a 404: the
    /// loader retries a client error within a second, and gives a not-found
    /// ten minutes.
    func testATruncatedRequestIsRefusedCheaply() throws {
        let (_, status) = try Self.rawRequest(["GET /tiles/3/4"], closeAfterWriting: true)

        XCTAssertEqual(status, 400)
    }

    /// `"?".split(separator: "?")` is empty, and the old code subscripted it,
    /// which traps and takes the whole test process down.
    func testARequestTargetOfOnlyAQuestionMarkDoesNotTrap() throws {
        let (_, status) = try Self.rawRequest(["GET ? HTTP/1.1\r\nHost: fixture\r\n\r\n"])

        XCTAssertEqual(status, 404, "An empty path carries no tile, but it must be answered, not crashed on")
    }

    /// Writes the pieces to the fixture service over a raw socket, with a
    /// pause between them so they land in separate reads, and returns the
    /// status line's code and the body.
    private static func rawRequest(_ pieces: [String],
                                   closeAfterWriting: Bool = false) throws -> (body: Data, status: Int) {
        let tileBaseURL = try XCTUnwrap(FixtureTileService.shared.tileBaseURL)
        let port = try XCTUnwrap(tileBaseURL.port)

        let socketHandle = socket(AF_INET, SOCK_STREAM, 0)
        guard socketHandle >= 0 else {
            throw XCTSkip("A socket could not be opened in this environment")
        }
        defer { close(socketHandle) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socketHandle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            throw XCTSkip("The fixture service refused a raw connection in this environment")
        }

        for (index, piece) in pieces.enumerated() {
            _ = piece.withCString { write(socketHandle, $0, strlen($0)) }
            if index < pieces.count - 1 {
                // Long enough that the pieces cannot coalesce into one read.
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        if closeAfterWriting {
            shutdown(socketHandle, SHUT_WR)
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let readCount = read(socketHandle, &buffer, buffer.count)
            guard readCount > 0 else {
                break
            }
            response.append(contentsOf: buffer[0..<readCount])
        }

        let separator = Data("\r\n\r\n".utf8)
        let headerEnd = try XCTUnwrap(response.range(of: separator), "The answer carried no header block")
        let statusLine = String(decoding: response[response.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            .split(separator: "\r\n").first ?? ""
        let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "") ?? 0
        return (Data(response[headerEnd.upperBound...]), status)
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
    ///
    /// What it cannot see: settings that never appear at the call site.
    /// `capture(settings:)`, `RenderFrameEngine.init(settings:)` and
    /// `ImmersiveMapView.init(settings:)` all default to the shipped settings
    /// in their own signatures, so a call that omits the argument reaches the
    /// hosted service with nothing to grep for. One such call existed and is
    /// fixed; if another turns up, spell the argument out rather than trying
    /// to teach this check to read Swift.
    func testNoTestBuildsARuntimeFromTheShippedDefaults() throws {
        let thisFile = URL(fileURLWithPath: #filePath).standardizedFileURL
        let testsDirectory = thisFile.deletingLastPathComponent()
        // `Support/` at the top of the tests tree, and only there: a nested
        // `Support` folder somewhere else is not the fixture layer and must
        // still be checked.
        let supportDirectory = testsDirectory.appendingPathComponent("Support").standardizedFileURL
        let enumerator = FileManager.default.enumerator(at: testsDirectory, includingPropertiesForKeys: nil)

        var offenders: [String] = []
        var scannedFiles = 0
        var runtimeFiles = 0
        for case let fileURL as URL in enumerator ?? .init() where fileURL.pathExtension == "swift" {
            scannedFiles += 1
            // Support owns the fixture layer itself and the harness that
            // rewrites settings before the engine sees them; this file spells
            // the patterns out and would otherwise report itself.
            let standardized = fileURL.standardizedFileURL
            guard standardized.deletingLastPathComponent() != supportDirectory,
                  standardized != thisFile else {
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

    /// Everything that turns settings into a transport, not just the public
    /// names.
    ///
    /// The first version of this list held the five entry points an app calls,
    /// and it was wrong: `RenderFrameEngine` builds a `RenderPersistentContext`,
    /// which builds a `TileRenderStore`, which builds an
    /// `ImmersiveMapNeedsTile`, which builds a `DefaultTileLoadPipeline`,
    /// which builds a `TileDownloader`, whose `init` fires the TileJSON
    /// request before a frame is ever asked for. Three test files reached the
    /// hosted service through that chain while this check watched the layer
    /// above and reported nothing. The list now names the chain itself.
    private static let runtimeEntryPoints = ["ImmersiveMapNSView(",
                                             "ImmersiveMapUIView(",
                                             "ImmersiveMapStillRecorder(",
                                             "ImmersiveMapTourVideoRecorder(",
                                             "ImmersiveMapVideoExportAttachContext(",
                                             "ImmersiveMapHostRuntime(",
                                             "ImmersiveMapRuntimeGraph(",
                                             "RenderFrameEngine(",
                                             "RenderPersistentContext(",
                                             "TileRenderStore(",
                                             // These two have an initializer that takes the
                                             // pipeline (or the downloader) already built, which
                                             // is how their own tests drive them and which touches
                                             // nothing. Only the convenience that assembles the
                                             // transport out of settings is a way to the network,
                                             // and it is the one that takes a tile render store.
                                             "ImmersiveMapNeedsTile(tileRenderStore:",
                                             "DefaultTileLoadPipeline(tileRenderStore:",
                                             "TileDownloader(config:"]

    /// How the shipped defaults are spelled where they are handed to one.
    /// `config:` is the name every internal seam uses, `settings:` the public
    /// one, and a bare `ImmersiveMapTilesProvider()` is the hosted service
    /// itself: its `tileBaseURL` defaults to `tiles.immersivemap.dev`.
    private static let defaultSettings = ["ImmersiveMapSettings.default",
                                          "settings: .default",
                                          "config: .default",
                                          "currentSettings: { .default }",
                                          "ImmersiveMapTilesProvider()"]

    /// Whether the line turns the shipped defaults into settings a runtime
    /// could be built from, and does so without going through `FixtureTiles`.
    ///
    /// `ImmersiveMapSettings.default.presentation` reads one block out of the
    /// defaults for a piece of arithmetic and never reaches a transport;
    /// `ImmersiveMapSettings.default.debugPanel(true)` is whole settings with
    /// the hosted tile service still in them. Textually the two differ by the
    /// call parentheses, which is what this looks for.
    private static func buildsSettingsFromTheShippedDefaults(_ line: Substring) -> Bool {
        // Comments and assertions cannot build anything. Stripping them keeps
        // the check off prose that merely names the pattern, including prose
        // explaining this rule.
        let code = line.ranges(of: "//").first.map { line[line.startIndex..<$0.lowerBound] } ?? line
        guard code.trimmingCharacters(in: .whitespaces).hasPrefix("XCTAssert") == false else {
            return false
        }
        for marker in defaultSettings {
            for range in code.ranges(of: marker) where isSettingsValue(code[range.upperBound...])
            && isInsideAFixtureCall(code[code.startIndex..<range.lowerBound]) == false {
                return true
            }
        }
        return false
    }

    /// Whether the defaults are being handed to `FixtureTiles` as a base to
    /// rewrite, which is the one legitimate way to name them next to a
    /// runtime.
    ///
    /// Deliberately narrower than "the line mentions FixtureTiles somewhere":
    /// `FixtureTiles.settings().tileProvider(ImmersiveMapTilesProvider())`
    /// undoes the fixture on the same line that would have excused it.
    private static func isInsideAFixtureCall(_ before: Substring) -> Bool {
        before.hasSuffix("FixtureTiles.settings(") || before.hasSuffix("FixtureTiles.tilelessSettings(")
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
