// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The API key path: what `apiKey(_:)` puts into the settings, and that it
/// survives being combined with a provider in either order.
final class ImmersiveMapAPIKeyTests: XCTestCase {
    private let key = "im_0123456789abcdef"

    func testAPIKeyTravelsAsABearerHeader() {
        let settings = ImmersiveMapSettings.default.apiKey(key)

        XCTAssertEqual(settings.tiles.network.authorizationToken, key)
        // A key in the query string would land in the CDN cache key, giving
        // every customer a private copy of identical tiles.
        XCTAssertEqual(settings.tiles.network.authorizationMode, .bearerHeader)
    }

    func testHostedProviderSendsItsKeyAsABearerHeader() {
        let settings = ImmersiveMapSettings.default
            .tileProvider(ImmersiveMapTilesProvider(apiKey: key))

        XCTAssertEqual(settings.tiles.network.authorizationToken, key)
        XCTAssertEqual(settings.tiles.network.authorizationMode, .bearerHeader)
    }

    func testKeylessProviderStaysAnonymous() {
        // The public pool must keep working without an account.
        let settings = ImmersiveMapSettings.default.tileProvider(ImmersiveMapTilesProvider())

        XCTAssertNil(settings.tiles.network.authorizationToken)
    }

    func testAPIKeyDoesNotDisturbTheRestOfTheProvider() {
        let base = ImmersiveMapSettings.default.tileProvider(ImmersiveMapTilesProvider())
        let keyed = base.apiKey(key)

        XCTAssertEqual(keyed.tiles.network.tileBaseURL, base.tiles.network.tileBaseURL)
        XCTAssertEqual(keyed.tiles.network.tileJSONURL, base.tiles.network.tileJSONURL)
        XCTAssertEqual(keyed.tiles.network.cacheIdentity, base.tiles.network.cacheIdentity)
        XCTAssertEqual(keyed.tiles.coverage.maximumZoomLevel, base.tiles.coverage.maximumZoomLevel)
        XCTAssertEqual(keyed.tileProvider.id, base.tileProvider.id)
    }

    func testAPIKeyAppliesToACustomEndpoint() {
        let endpoint = URL(string: "https://tiles.example.com/tiles")!
        let settings = ImmersiveMapSettings.default
            .tileProvider(ImmersiveMapTilesProvider(tileBaseURL: endpoint))
            .apiKey(key)

        XCTAssertEqual(settings.tiles.network.tileBaseURL, endpoint)
        XCTAssertEqual(settings.tiles.network.authorizationToken, key)
    }

    /// Attaching a provider rewrites the whole authorization block, so a key set
    /// beforehand would be dropped if the view applied it eagerly. The view
    /// resolves it at render time instead — this pins that both orders agree.
    func testViewModifierOrderDoesNotMatter() {
        let provider = ImmersiveMapTilesProvider()
        let keyFirst = ImmersiveMapView()
            .apiKey(key)
            .tileProvider(provider)
        let keyLast = ImmersiveMapView()
            .tileProvider(provider)
            .apiKey(key)

        for (label, view) in [("key first", keyFirst), ("key last", keyLast)] {
            let network = view.resolvedSettings.tiles.network
            XCTAssertEqual(network.authorizationToken, key, "\(label): key was lost")
            XCTAssertEqual(network.authorizationMode, .bearerHeader, "\(label): wrong authorization mode")
        }
    }

    func testEmptyKeyIsIgnored() {
        let view = ImmersiveMapView().apiKey("")

        XCTAssertNil(view.resolvedSettings.tiles.network.authorizationToken)
    }
}
