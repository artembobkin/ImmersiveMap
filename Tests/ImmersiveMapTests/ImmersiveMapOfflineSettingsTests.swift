// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import XCTest
@testable import ImmersiveMap

/// The offline settings surface: the default, the settings builders, and the
/// `ImmersiveMapView` modifiers that mirror them.
@MainActor
final class ImmersiveMapOfflineSettingsTests: XCTestCase {
    func testOfflineModeDefaultsToAutomatic() {
        XCTAssertEqual(ImmersiveMapSettings.default.tiles.offline.mode, .automatic)
        XCTAssertEqual(ImmersiveMapSettings.TileSettings.OfflineSettings().mode, .automatic)
    }

    func testSettingsBuildersReplaceOnlyTheOfflineBranch() {
        let base = ImmersiveMapSettings.default

        let offlineOnly = base.offlineTileMode(.offlineOnly)
        XCTAssertEqual(offlineOnly.tiles.offline.mode, .offlineOnly)
        XCTAssertEqual(offlineOnly.tiles.network, base.tiles.network)
        XCTAssertEqual(offlineOnly.tiles.cache, base.tiles.cache)

        let replaced = base.offlineTileSettings(.init(mode: .disabled))
        XCTAssertEqual(replaced.tiles.offline.mode, .disabled)
    }

    func testViewModifiersStoreTheMode() {
        let view = ImmersiveMapView()
            .offlineTileMode(.offlineOnly)
        XCTAssertEqual(view.settings.tiles.offline.mode, .offlineOnly)

        let replaced = ImmersiveMapView()
            .offlineTileSettings(.init(mode: .disabled))
        XCTAssertEqual(replaced.settings.tiles.offline.mode, .disabled)
    }

    func testTileProviderFanOutLeavesTheOfflineModeAlone() {
        let settings = ImmersiveMapSettings.default
            .offlineTileMode(.offlineOnly)
            .tileProvider(ImmersiveMapTilesProvider())
        XCTAssertEqual(settings.tiles.offline.mode, .offlineOnly)
    }
}
