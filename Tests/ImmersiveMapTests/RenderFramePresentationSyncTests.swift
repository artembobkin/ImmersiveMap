// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import QuartzCore
import XCTest

/// Renders live frames through `RenderFrameEngine.render(to:drawable:)` with
/// drawables acquired from a headless `CAMetalLayer` (standing in for the
/// ones a `CAMetalDisplayLink` update delivers) and asserts the marker-driven
/// presentation sync: while SwiftUI annotations exist the layer must present
/// within the CATransaction (otherwise marker views trail the map by a frame
/// during camera motion), and without markers the free-running present must
/// come back. Requires the compiled Metal library, so it skips under
/// `swift test` and runs in the xcodebuild workspace suite.
final class RenderFramePresentationSyncTests: XCTestCase {
    private final class StubPinSource: PinRenderSource {
        var currentPinController: ImmersiveMapPinsController? { nil }
    }

    private final class MutableAnnotationSource: AnnotationRenderSource {
        var input: AnnotationProjectionInput = .empty
        var currentAnnotationProjectionInput: AnnotationProjectionInput { input }
    }

    private final class StubSceneModelSource: SceneModelRenderSource {
        var currentSceneModelsController: ImmersiveMapSceneModelsController? { nil }
    }

    @MainActor
    func testPresentsWithTransactionFollowsMarkerPresence() throws {
        guard let probeDevice = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        guard (try? probeDevice.makeDefaultLibrary(bundle: ImmersiveMapResourceBundle.bundle())) != nil else {
            throw XCTSkip("Compiled Metal library is unavailable in this test environment")
        }

        let settings = FixtureTiles.tilelessSettings()
        let clock = RenderFrameScriptedClock()
        let eventSink = VideoExportRenderEventSink()
        let annotationSource = MutableAnnotationSource()
        let layer = CAMetalLayer()
        let engine = try RenderFrameEngine(layer: layer,
                                           pinSource: StubPinSource(),
                                           annotationSource: annotationSource,
                                           sceneModelSource: StubSceneModelSource(),
                                           styleRuntime: MapStyleRuntime(settings: settings),
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

        annotationSource.input = AnnotationProjectionInput(entries: [
            AnnotationProjectionEntry(id: 1,
                                  basis: GeoProjectionBasis(coordinate: GeoCoordinate(latitude: 40.7,
                                                                                      longitude: -74.0)))
        ])
        clock.setTime(0)
        let annotationDrawable = try XCTUnwrap(layer.nextDrawable())
        XCTAssertTrue(engine.render(to: layer, drawable: annotationDrawable),
                      "The marker frame must schedule")
        XCTAssertTrue(layer.presentsWithTransaction,
                      "With markers the drawable must present inside the CATransaction")
        let annotationSnapshot = try XCTUnwrap(eventSink.annotationProjectionSnapshot,
                                           "The marker snapshot publishes synchronously with the scheduled frame")
        XCTAssertEqual(annotationSnapshot.drawSize,
                       CGSize(width: annotationDrawable.texture.width,
                              height: annotationDrawable.texture.height),
                       "The frame must measure itself against the drawable it renders into")

        annotationSource.input = .empty
        clock.setTime(1.0 / 60.0)
        let annotationFreeDrawable = try XCTUnwrap(layer.nextDrawable())
        XCTAssertTrue(engine.render(to: layer, drawable: annotationFreeDrawable),
                      "The marker-free frame must schedule")
        XCTAssertFalse(layer.presentsWithTransaction,
                       "Without markers the layer returns to free-running presentation")
    }
}
