// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

#if os(macOS)

import AppKit
import Metal
import XCTest
@testable import ImmersiveMap

/// View reuse: a dismantled host view parks in the pool and the next map view
/// adopts it with its renderer and tile store intact (requires compiled Metal,
/// so the tests skip under `swift test` and run fully under xcodebuild).
final class ImmersiveMapHostViewPoolTests: XCTestCase {
    @MainActor
    func testParkedViewIsAdoptedWithRendererAndTileStoreIntact() throws {
        try skipUnlessMetalAvailable()

        let pool = ImmersiveMapHostViewPool()
        let view = makeHostView()
        let tileStoreBeforeParking = view.rendererForTesting?.persistentContextForTesting.tileRenderStore

        view.dismantle()
        pool.park(view, timeToLive: 30)
        let adopted = pool.adopt()

        XCTAssertTrue(adopted === view, "Adoption must hand back the parked instance")
        XCTAssertNil(pool.adopt(), "A second adoption must find an empty pool")
        XCTAssertNotNil(tileStoreBeforeParking)
        XCTAssertTrue(adopted?.rendererForTesting?.persistentContextForTesting.tileRenderStore === tileStoreBeforeParking,
                      "The warm tile store is the point of parking and must survive")
    }

    @MainActor
    func testAdoptionReconcilesSettingsThroughTheUpdatePath() throws {
        try skipUnlessMetalAvailable()

        let pool = ImmersiveMapHostViewPool()
        let view = makeHostView()
        view.dismantle()
        pool.park(view, timeToLive: 30)

        var settings = FixtureTiles.tilelessSettings()
        settings.camera.minimumZoom = 3
        let adopted = try XCTUnwrap(pool.adopt())
        adopted.prepareForAdoption(settings: settings,
                                   avatarsController: nil,
                                   sceneModelsController: nil,
                                   routesController: nil,
                                   cameraPosition: nil,
                                   cameraController: nil,
                                   selectionController: nil,
                                   avatarTapAction: nil,
                                   markerContent: nil)

        XCTAssertEqual(adopted.cameraRuntime.currentSettings.camera.minimumZoom, 3)
    }

    @MainActor
    func testParkedViewExpiresAfterTimeToLive() async throws {
        try skipUnlessMetalAvailable()

        let pool = ImmersiveMapHostViewPool()
        let view = makeHostView()
        view.dismantle()
        pool.park(view, timeToLive: 0.05)

        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertFalse(pool.hasParkedViewForTesting, "TTL expiry must release the parked view")
        XCTAssertNil(pool.adopt())
    }

    @MainActor
    func testMemoryPressureDrainReleasesParkedView() throws {
        try skipUnlessMetalAvailable()

        let pool = ImmersiveMapHostViewPool()
        let view = makeHostView()
        view.dismantle()
        pool.park(view, timeToLive: 30)

        pool.drain()

        XCTAssertFalse(pool.hasParkedViewForTesting)
        XCTAssertNil(pool.adopt())
    }

    @MainActor
    func testNewerParkedViewReplacesOlderOne() throws {
        try skipUnlessMetalAvailable()

        let pool = ImmersiveMapHostViewPool()
        let older = makeHostView()
        let newer = makeHostView()
        older.dismantle()
        newer.dismantle()

        pool.park(older, timeToLive: 30)
        pool.park(newer, timeToLive: 30)

        XCTAssertTrue(pool.adopt() === newer, "The most recently parked view is the warmest one")
        XCTAssertNil(pool.adopt())
    }

    @MainActor
    func testDismantleForReuseHonorsDisabledSetting() throws {
        try skipUnlessMetalAvailable()

        var settings = FixtureTiles.tilelessSettings()
        settings.viewReuse.isEnabled = false
        let view = ImmersiveMapNSView(frame: .zero, settings: settings)

        ImmersiveMapHostViewPool.shared.drain()
        view.dismantleForReuse()

        XCTAssertFalse(ImmersiveMapHostViewPool.shared.hasParkedViewForTesting,
                       "Reuse disabled in settings must not park the view")
    }

    @MainActor
    func testDismantleForReuseParksByDefault() throws {
        try skipUnlessMetalAvailable()

        let view = makeHostView()

        ImmersiveMapHostViewPool.shared.drain()
        view.dismantleForReuse()

        XCTAssertTrue(ImmersiveMapHostViewPool.shared.hasParkedViewForTesting)
        XCTAssertTrue(ImmersiveMapHostViewPool.shared.adopt() === view)
    }

    @MainActor
    func testParkClampsNonFiniteTimeToLive() throws {
        try skipUnlessMetalAvailable()

        let pool = ImmersiveMapHostViewPool()
        let view = makeHostView()
        view.dismantle()

        pool.park(view, timeToLive: .infinity)

        XCTAssertTrue(pool.hasParkedViewForTesting, "Infinite TTL must clamp, not trap")
        XCTAssertTrue(pool.adopt() === view)
    }

    /// The dedup against the last SwiftUI-declared position must not survive
    /// adoption: a screen declaring the same position as the previous life
    /// expects the camera to actually move there.
    @MainActor
    func testAdoptionReappliesTheSameDeclaredCameraPosition() throws {
        try skipUnlessMetalAvailable()

        let declared = ImmersiveMapCameraPosition(latitudeDegrees: 48.8566,
                                                  longitudeDegrees: 2.3522,
                                                  zoom: 6)
        let elsewhere = ImmersiveMapCameraPosition(latitudeDegrees: 51.5072,
                                                   longitudeDegrees: -0.1276,
                                                   zoom: 9)
        let view = makeHostView()
        view.update(settings: FixtureTiles.tilelessSettings(),
                    avatarsController: nil,
                    cameraController: nil,
                    selectionController: nil,
                    avatarTapAction: nil,
                    markerContent: nil,
                    cameraPosition: declared)

        // The user "pans away": complete a flight to another city.
        view.flyForTesting(to: elsewhere,
                           options: CameraFlightOptions(duration: 0.1),
                           currentTime: CACurrentMediaTime())
        view.advanceCameraFlightForTesting(currentTime: CACurrentMediaTime() + 1.0)

        ImmersiveMapHostViewPool.shared.drain()
        view.dismantleForReuse()
        let adopted = try XCTUnwrap(ImmersiveMapHostViewPool.shared.adopt())
        adopted.prepareForAdoption(settings: FixtureTiles.tilelessSettings(),
                                   avatarsController: nil,
                                   sceneModelsController: nil,
                                   routesController: nil,
                                   cameraPosition: declared,
                                   cameraController: nil,
                                   selectionController: nil,
                                   avatarTapAction: nil,
                                   markerContent: nil)

        let position = try XCTUnwrap(adopted.cameraRuntime.currentCameraPosition())
        XCTAssertEqual(position.latitudeDegrees, declared.latitudeDegrees, accuracy: 0.01)
        XCTAssertEqual(position.longitudeDegrees, declared.longitudeDegrees, accuracy: 0.01)
    }

    @MainActor
    private func makeHostView() -> ImmersiveMapNSView {
        ImmersiveMapNSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240),
                           settings: FixtureTiles.tilelessSettings())
    }

    private func skipUnlessMetalAvailable() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        guard (try? device.makeDefaultLibrary(bundle: .module)) != nil else {
            throw XCTSkip("Compiled Metal library is unavailable in this test environment")
        }
    }
}

#endif
