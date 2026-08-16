// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The URL-template tile source: `{x}`/`{y}`/`{z}` substitution with the query
/// string preserved, custom request headers on every download, and both folded
/// into the cache identities so a source change never serves another source's
/// prepared tiles.
final class TileURLTemplateSourceTests: XCTestCase {
    private let template = "https://tiles.com/{x}/{y}/{z}?apiKey=xxx"

    // MARK: - Source model

    func testTemplateFactoryStoresTemplateAndHeaders() {
        let source = ImmersiveMapTileSource.template(template, headers: ["X-Client": "demo"])

        XCTAssertEqual(source.urlTemplate, template)
        XCTAssertEqual(source.headers, ["X-Client": "demo"])
        XCTAssertNil(source.tileJSONURL)
        // The legacy base URL is derived and valid, for identity and logs only.
        XCTAssertEqual(source.tileBaseURL.host, "tiles.com")
    }

    func testHeadersBuilderMergesWithNewValuesWinning() {
        let source = ImmersiveMapTileSource.template(template, headers: ["A": "1", "B": "2"])
            .headers(["B": "3", "C": "4"])

        XCTAssertEqual(source.headers, ["A": "1", "B": "3", "C": "4"])
    }

    // MARK: - URL building

    func testTemplateProviderSubstitutesPlaceholdersAndKeepsTheQuery() {
        let provider = TemplateTileURLProvider(
            template: template,
            fallback: BackendTileURLProvider(baseURL: URL(string: "https://fallback.host/tiles")!))

        XCTAssertEqual(provider.get(tileX: 3, tileY: 5, tileZ: 4).absoluteString,
                       "https://tiles.com/3/5/4?apiKey=xxx")
    }

    func testTemplateProviderFallsBackWhenTheTemplateCannotFormAURL() {
        let provider = TemplateTileURLProvider(
            template: "not a url {x} {y} {z}",
            fallback: BackendTileURLProvider(baseURL: URL(string: "https://fallback.host/tiles")!))

        XCTAssertEqual(provider.get(tileX: 1, tileY: 2, tileZ: 3).absoluteString,
                       "https://fallback.host/tiles/3/1/2.mvt")
    }

    // MARK: - Request headers

    func testDownloaderSendsCustomHeadersOnEveryTileRequest() async {
        HeaderCapturingURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeaderCapturingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let downloader = TileDownloader(
            mapTileDownloader: TemplateTileURLProvider(
                template: template,
                fallback: BackendTileURLProvider(baseURL: URL(string: "https://fallback.host/tiles")!)),
            session: session,
            customHeaders: ["X-Client": "demo", "Authorization": "Bearer abc"])

        let result = await downloader.downloadResult(tile: Tile(x: 3, y: 5, z: 4))

        XCTAssertEqual(result, .success(Data([0x1A]), etag: nil))
        XCTAssertEqual(HeaderCapturingURLProtocol.capturedURL?.absoluteString,
                       "https://tiles.com/3/5/4?apiKey=xxx")
        XCTAssertEqual(HeaderCapturingURLProtocol.capturedHeaders["X-Client"], "demo")
        // Header-based credentials travel this way now, Authorization included.
        XCTAssertEqual(HeaderCapturingURLProtocol.capturedHeaders["Authorization"], "Bearer abc")
    }

    // MARK: - Settings plumbing

    func testTileProviderSettingsCopyTemplateAndHeadersIntoNetworkSettings() {
        let provider = VectorTileProvider(
            id: "templated",
            tileSource: .template(template, headers: ["X-Client": "demo"]))

        let settings = ImmersiveMapSettings.default.tileProvider(provider)

        XCTAssertEqual(settings.tiles.network.tileURLTemplate, template)
        XCTAssertEqual(settings.tiles.network.tileRequestHeaders, ["X-Client": "demo"])
    }

    func testBuiltInProviderRunsOverACustomTileSourceVerbatim() {
        let source = ImmersiveMapTileSource.template(template, headers: ["X-Client": "demo"])

        let provider = ImmersiveMapTilesProvider(tileSource: source)

        XCTAssertEqual(provider.tileSource, source)
        XCTAssertNotEqual(provider.configurationFingerprint,
                          ImmersiveMapTilesProvider().configurationFingerprint)
    }

    // MARK: - Cache identity

    func testCacheIdentitiesTrackTheTemplateAndHeaderNamesButNotHeaderValues() {
        func network(template: String?, headers: [String: String]) -> ImmersiveMapSettings.TileSettings.NetworkSettings {
            ImmersiveMapSettings.TileSettings.NetworkSettings(
                maxConcurrentFetches: 5,
                pendingRequestQueueCapacity: 64,
                tileURLTemplate: template,
                tileRequestHeaders: headers)
        }
        let base = PreparedTileCacheIdentity.tileSourceRevision(for: network(template: nil, headers: [:]))
        let templated = PreparedTileCacheIdentity.tileSourceRevision(for: network(template: template, headers: [:]))
        let named = PreparedTileCacheIdentity.tileSourceRevision(for: network(template: template, headers: ["X-Key": "a"]))
        let rotated = PreparedTileCacheIdentity.tileSourceRevision(for: network(template: template, headers: ["X-Key": "b"]))

        XCTAssertNotEqual(base, templated)
        XCTAssertNotEqual(templated, named)
        // Rotating a credential must not cold-start the prepared cache.
        XCTAssertEqual(named, rotated)
    }

    func testVectorTileProviderFingerprintTracksTemplateAndHeaderNames() {
        func fingerprint(_ source: ImmersiveMapTileSource) -> UInt64 {
            VectorTileProvider(id: "templated", tileSource: source).configurationFingerprint
        }
        let url = URL(string: "https://tiles.com/0/0/0?apiKey=xxx")!
        let plain = fingerprint(.url(url))
        let templated = fingerprint(.template(template))
        let named = fingerprint(.template(template, headers: ["X-Key": "a"]))
        let rotated = fingerprint(.template(template, headers: ["X-Key": "b"]))

        XCTAssertNotEqual(plain, templated)
        XCTAssertNotEqual(templated, named)
        XCTAssertEqual(named, rotated)
    }
}

private final class HeaderCapturingURLProtocol: URLProtocol {
    nonisolated(unsafe) static var capturedURL: URL?
    nonisolated(unsafe) static var capturedHeaders: [String: String] = [:]

    static func reset() {
        capturedURL = nil
        capturedHeaders = [:]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedURL = request.url
        Self.capturedHeaders = request.allHTTPHeaderFields ?? [:]
        let response = HTTPURLResponse(url: request.url!,
                                       statusCode: 200,
                                       httpVersion: nil,
                                       headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([0x1A]))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
