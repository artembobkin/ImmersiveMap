// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import QuartzCore
import XCTest

/// Renders live frames through `RenderFrameEngine.render(to:drawable:presentAt:)`
/// with drawables acquired from a headless `CAMetalLayer` (standing in for the
/// ones a `CAMetalDisplayLink` update delivers) and asserts the presentation
/// contract: every live frame is scheduled for the instant it was computed
/// for, through one path, whether or not SwiftUI markers exist. That shared
/// instant is what holds the map and the marker views together, so the layer
/// must never be switched into the blocking transaction-synced mode. Requires
/// the compiled Metal library, so it skips under `swift test` and runs in the
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
    private func makeEngine(layer: CAMetalLayer,
                            markerSource: MarkerRenderSource,
                            clock: RenderFrameScriptedClock,
                            eventSink: VideoExportRenderEventSink) throws -> RenderFrameEngine {
        guard let probeDevice = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        guard (try? probeDevice.makeDefaultLibrary(bundle: .module)) != nil else {
            throw XCTSkip("Compiled Metal library is unavailable in this test environment")
        }

        let settings = ImmersiveMapSettings.default
        return RenderFrameEngine(layer: layer,
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
    }

    /// The transaction-synced mode blocks the main thread in
    /// `waitUntilScheduled` and used to be switched on and off per frame from
    /// the marker count, which made frame delivery depend on what the app
    /// happened to put on the map. Presenting at the frame's own target time
    /// binds map and markers without that, so the mode must stay off in both
    /// cases.
    @MainActor
    func testPresentationStaysFreeRunningWithAndWithoutMarkers() throws {
        let clock = RenderFrameScriptedClock()
        let eventSink = VideoExportRenderEventSink()
        let markerSource = MutableMarkerSource()
        let layer = CAMetalLayer()
        let engine = try makeEngine(layer: layer,
                                    markerSource: markerSource,
                                    clock: clock,
                                    eventSink: eventSink)
        layer.drawableSize = CGSize(width: 64, height: 64)
        XCTAssertFalse(layer.presentsWithTransaction,
                       "A fresh layer starts in free-running presentation")

        markerSource.input = MarkerProjectionInput(entries: [
            MarkerProjectionEntry(id: 1,
                                  basis: GeoProjectionBasis(coordinate: GeoCoordinate(latitude: 40.7,
                                                                                      longitude: -74.0)))
        ])
        clock.setTime(0)
        let markerDrawable = try XCTUnwrap(layer.nextDrawable())
        XCTAssertTrue(engine.render(to: layer,
                                    drawable: markerDrawable,
                                    presentAt: CACurrentMediaTime() + 1.0 / 60.0),
                      "The marker frame must schedule")
        XCTAssertFalse(layer.presentsWithTransaction,
                       "Markers must not switch the layer into the blocking transaction-synced mode")

        let markerSnapshot = try XCTUnwrap(eventSink.markerProjectionSnapshot,
                                           "The marker snapshot publishes synchronously with the scheduled frame")
        XCTAssertEqual(markerSnapshot.drawSize,
                       CGSize(width: markerDrawable.texture.width,
                              height: markerDrawable.texture.height),
                       "The frame must measure itself against the drawable it renders into")

        markerSource.input = .empty
        clock.setTime(1.0 / 60.0)
        let markerFreeDrawable = try XCTUnwrap(layer.nextDrawable())
        XCTAssertTrue(engine.render(to: layer,
                                    drawable: markerFreeDrawable,
                                    presentAt: CACurrentMediaTime() + 2.0 / 60.0),
                      "The marker-free frame must schedule")
        XCTAssertFalse(layer.presentsWithTransaction,
                       "Removing markers must not change how frames are delivered either")
    }

    /// A target time that has already passed (a frame that missed its slot)
    /// must still present, at the next opportunity, rather than stall the
    /// drawable or fail the frame.
    @MainActor
    func testFrameWithAPastTargetTimeStillSchedules() throws {
        let clock = RenderFrameScriptedClock()
        let layer = CAMetalLayer()
        let engine = try makeEngine(layer: layer,
                                    markerSource: MutableMarkerSource(),
                                    clock: clock,
                                    eventSink: VideoExportRenderEventSink())
        layer.drawableSize = CGSize(width: 64, height: 64)

        clock.setTime(0)
        let drawable = try XCTUnwrap(layer.nextDrawable())

        XCTAssertTrue(engine.render(to: layer,
                                    drawable: drawable,
                                    presentAt: CACurrentMediaTime() - 1.0),
                      "A late frame must still be scheduled and presented")
    }
}
