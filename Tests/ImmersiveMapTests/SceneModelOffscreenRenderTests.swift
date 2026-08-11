// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// End-to-end: a scene model anchored at the camera center must change the
/// rendered pixels of a headless frame once its mesh loads, and the hit volume
/// the frame publishes must cover the model where it was drawn. Requires the
/// compiled Metal library, so it skips under `swift test` and runs in the
/// xcodebuild workspace suite.
final class SceneModelOffscreenRenderTests: XCTestCase {
    /// Keeps the last selection snapshot the engine published; it arrives on
    /// the Metal completion thread, hence the lock.
    private final class RecordingEventSink: RenderFrameEventSink, @unchecked Sendable {
        private let lock = NSLock()
        private var latestSceneModelSnapshot: SceneModelSelectionSnapshot = .empty

        var sceneModelSelectionSnapshot: SceneModelSelectionSnapshot {
            lock.withLock { latestSceneModelSnapshot }
        }

        func invalidate(_ reason: RenderInvalidationReason) {}
        func applyActivityState(_ state: RenderActivityState) {}
        func completeSceneModelPathAnimations(_: [SceneModelPathAnimationResult]) {}
        func updateAvatarSelectionSnapshot(_ snapshot: AvatarSelectionSnapshot) {}
        func updateDebugOverlayHUDSnapshot(_ snapshot: DebugOverlayHUDSnapshot?) {}
        func updateMarkerProjectionSnapshot(_ snapshot: MarkerProjectionSnapshot) {}

        func updateSceneModelSelectionSnapshot(_ snapshot: SceneModelSelectionSnapshot) {
            lock.withLock { latestSceneModelSnapshot = snapshot }
        }
    }

    @MainActor
    func testAnchoredModelChangesRenderedPixels() async throws {
        let size = 128
        let eventSink = RecordingEventSink()
        let harness = try OffscreenFrameHarness.makeOrSkip(size: size, eventSink: eventSink)

        let baseline = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(0))

        // A continent-sized obelisk at the camera center: visible at any zoom,
        // so the test does not depend on the resolver's default position.
        let cameraPosition = harness.cameraPosition
        let objURL = try writeCubeOBJ()
        defer { try? FileManager.default.removeItem(at: objURL) }
        let modelCoordinate = GeoCoordinate(latitude: cameraPosition.latitudeDegrees,
                                            longitude: cameraPosition.longitudeDegrees)
        harness.sceneModels.add(ImmersiveMapSceneModel(
            id: 1,
            source: ImmersiveMapSceneModel.Source(url: objURL),
            coordinate: modelCoordinate,
            fitDiameterMeters: 2_000_000))

        // The mesh loads asynchronously off-main: keep rendering until the
        // model rasterizes or the deadline passes. Changed pixels alone do not
        // prove it arrived (tiles stream in and change them too), so the drawn
        // model is awaited through the hit volume the frame publishes for it.
        var pixelsChanged = false
        var snapshot = SceneModelSelectionSnapshot.empty
        for frameIndex in 1...200 {
            let frame = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(frameIndex))
            pixelsChanged = pixelsChanged || frame != baseline
            snapshot = eventSink.sceneModelSelectionSnapshot
            if pixelsChanged, snapshot.entries.isEmpty == false {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertTrue(pixelsChanged,
                      "A loaded scene model at the camera center must alter the rendered frame")

        // The frame that drew the model must publish a hit volume for it, with
        // that frame's own camera, so a tap resolves against what is visible.
        let entry = try XCTUnwrap(snapshot.entries.first, "The drawn model must reach the selection snapshot")
        XCTAssertEqual(snapshot.entries.count, 1)
        XCTAssertEqual(entry.id, 1)
        XCTAssertEqual(entry.coordinate.latitude, modelCoordinate.latitude, accuracy: 1e-9)
        XCTAssertEqual(snapshot.drawSize, CGSize(width: size, height: size))

        let projected = try XCTUnwrap(SceneModelPickMath.screenBounds(boundsMin: entry.boundsMin,
                                                                      boundsMax: entry.boundsMax,
                                                                      modelMatrix: entry.modelMatrix,
                                                                      projectionView: snapshot.projectionView,
                                                                      drawSize: snapshot.drawSize),
                                      "The model must project in front of the camera")
        XCTAssertTrue(projected.intersects(CGRect(x: 0, y: 0, width: size, height: size)),
                      "The model the frame painted must project inside the drawable")
        XCTAssertEqual(snapshot.hitTest(point: CGPoint(x: projected.midX, y: projected.midY),
                                        minimumTouchSizePixels: 0)?.id,
                       1,
                       "A tap at the model's own projected center must hit it")
    }

    private func writeCubeOBJ() throws -> URL {
        let obj = """
        v -1 0 -1
        v 1 0 -1
        v 1 2 -1
        v -1 2 -1
        v -1 0 1
        v 1 0 1
        v 1 2 1
        v -1 2 1
        f 1 3 2
        f 1 4 3
        f 5 6 7
        f 5 7 8
        f 1 2 6
        f 1 6 5
        f 2 3 7
        f 2 7 6
        f 3 4 8
        f 3 8 7
        f 4 1 5
        f 4 5 8
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scene-model-offscreen-\(UUID().uuidString)")
            .appendingPathExtension("obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
