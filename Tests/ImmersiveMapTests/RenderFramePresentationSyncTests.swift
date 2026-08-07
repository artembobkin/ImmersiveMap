// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import QuartzCore
import XCTest

/// Renders live frames through `RenderFrameEngine.render(to:)` into a headless
/// `CAMetalLayer` and asserts the marker-driven presentation sync: while
/// SwiftUI markers exist the layer must present within the CATransaction
/// (otherwise marker views trail the map by a frame during camera motion), and
/// without markers the free-running present must come back. Requires the
/// compiled Metal library, so it skips under `swift test` and runs in the
/// xcodebuild workspace suite.
final class RenderFramePresentationSyncTests: XCTestCase {
    private final class StubAvatarSource: AvatarRenderSource {
        var currentAvatarController: ImmersiveMapAvatarsController? { nil }
    }

    private final class MutableMarkerSource: MarkerRenderSource {
        var input: MarkerProjectionInput = .empty
        var currentMarkerProjectionInput: MarkerProjectionInput { input }
    }

    private final class StubSceneModelSource: SceneModelRenderSource {
        var currentSceneModelsController: ImmersiveMapSceneModelsController? { nil }
    }

    private final class StubRouteSource: RouteRenderSource {
        var currentRoutesController: ImmersiveMapRoutesController? { nil }
    }

    @MainActor
    func testPresentsWithTransactionFollowsMarkerPresence() throws {
        guard let probeDevice = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        guard (try? probeDevice.makeDefaultLibrary(bundle: .module)) != nil else {
            throw XCTSkip("Compiled Metal library is unavailable in this test environment")
        }

        let settings = ImmersiveMapSettings.default
        let clock = RenderFrameScriptedClock()
        let eventSink = VideoExportRenderEventSink()
        let markerSource = MutableMarkerSource()
        let layer = CAMetalLayer()
        let engine = RenderFrameEngine(layer: layer,
                                       avatarSource: StubAvatarSource(),
                                       markerSource: markerSource,
                                       sceneModelSource: StubSceneModelSource(),
                                       routeSource: StubRouteSource(),
                                       providerRuntime: ImmersiveMapProviderRuntimeContext(settings: settings),
                                       settings: settings,
                                       renderCamera: FrameCameraStateResolver(settings: settings),
                                       presentationStateResolver: MapPresentationStateController(settings: settings),
                                       eventSink: eventSink,
                                       tileTraceRecorder: TileTraceRecorder(),
                                       baseLabelTraceRecorder: BaseLabelTraceRecorder(),
                                       clock: clock)
        layer.drawableSize = CGSize(width: 64, height: 64)
        XCTAssertFalse(layer.presentsWithTransaction,
                       "A fresh layer starts in free-running presentation")

        markerSource.input = MarkerProjectionInput(entries: [
            MarkerProjectionEntry(id: 1,
                                  basis: GeoProjectionBasis(coordinate: GeoCoordinate(latitude: 40.7,
                                                                                      longitude: -74.0)))
        ])
        clock.setTime(0)
        XCTAssertTrue(engine.render(to: layer),
                      "The marker frame must schedule")
        XCTAssertTrue(layer.presentsWithTransaction,
                      "With markers the drawable must present inside the CATransaction")
        XCTAssertNotNil(eventSink.markerProjectionSnapshot,
                        "The marker snapshot publishes synchronously with the scheduled frame")

        markerSource.input = .empty
        clock.setTime(1.0 / 60.0)
        XCTAssertTrue(engine.render(to: layer),
                      "The marker-free frame must schedule")
        XCTAssertFalse(layer.presentsWithTransaction,
                       "Without markers the layer returns to free-running presentation")
    }
}
