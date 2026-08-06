// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import QuartzCore
import XCTest

/// End-to-end: a scene model anchored at the camera center must change the
/// rendered pixels of a headless frame once its mesh loads, and the hit volume
/// the frame publishes must cover the model where it was drawn. Requires the
/// compiled Metal library, so it skips under `swift test` and runs in the
/// xcodebuild workspace suite.
final class SceneModelOffscreenRenderTests: XCTestCase {
    private final class StubAvatarSource: AvatarRenderSource {
        var currentAvatarController: ImmersiveMapAvatarsController? { nil }
    }

    private final class StubMarkerSource: MarkerRenderSource {
        var currentMarkerProjectionInput: MarkerProjectionInput { .empty }
    }

    private final class StubSceneModelSource: SceneModelRenderSource {
        let controller = ImmersiveMapSceneModelsController()
        var currentSceneModelsController: ImmersiveMapSceneModelsController? { controller }
    }

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
        guard let probeDevice = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        guard (try? probeDevice.makeDefaultLibrary(bundle: .module)) != nil else {
            throw XCTSkip("Compiled Metal library is unavailable in this test environment")
        }
        guard probeDevice.hasUnifiedMemory else {
            throw XCTSkip("Unified-memory GPU is required for direct texture readback")
        }

        let settings = ImmersiveMapSettings.default
        let clock = RenderFrameScriptedClock()
        let eventSink = RecordingEventSink()
        let renderCamera = FrameCameraStateResolver(settings: settings)
        let presentation = MapPresentationStateController(settings: settings)
        let sceneModelSource = StubSceneModelSource()
        let layer = CAMetalLayer()
        let engine = RenderFrameEngine(layer: layer,
                                       avatarSource: StubAvatarSource(),
                                       markerSource: StubMarkerSource(),
                                       sceneModelSource: sceneModelSource,
                                       routeSource: StubRouteSource(),
                                       providerRuntime: ImmersiveMapProviderRuntimeContext(settings: settings),
                                       settings: settings,
                                       renderCamera: renderCamera,
                                       presentationStateResolver: presentation,
                                       eventSink: eventSink,
                                       tileTraceRecorder: TileTraceRecorder(),
                                       baseLabelTraceRecorder: BaseLabelTraceRecorder(),
                                       clock: clock)
        let device = try XCTUnwrap(layer.device)

        let size = 128
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: size,
                                                                  height: size,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))

        let baseline = try await renderFrame(engine: engine, clock: clock, texture: texture, time: 0, size: size)

        // A continent-sized obelisk at the camera center: visible at any zoom,
        // so the test does not depend on the resolver's default position.
        let cameraPosition = renderCamera.currentCameraPosition()
        let objURL = try writeCubeOBJ()
        defer { try? FileManager.default.removeItem(at: objURL) }
        let modelCoordinate = GeoCoordinate(latitude: cameraPosition.latitudeDegrees,
                                            longitude: cameraPosition.longitudeDegrees)
        sceneModelSource.controller.add(ImmersiveMapSceneModel(
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
        for frameIndex in 1...200 where pixelsChanged == false || snapshot.entries.isEmpty {
            let pixels = try await renderFrame(engine: engine,
                                               clock: clock,
                                               texture: texture,
                                               time: TimeInterval(frameIndex) / 60.0,
                                               size: size)
            pixelsChanged = pixelsChanged || pixels != baseline
            snapshot = eventSink.sceneModelSelectionSnapshot
            if pixelsChanged == false || snapshot.entries.isEmpty {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
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

    @MainActor
    private func renderFrame(engine: RenderFrameEngine,
                             clock: RenderFrameScriptedClock,
                             texture: MTLTexture,
                             time: TimeInterval,
                             size: Int) async throws -> [UInt8] {
        clock.setTime(time)
        let didComplete = await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            let request = RenderFrameOffscreenRequest(texture: texture,
                                                      drawSize: CGSize(width: size, height: size),
                                                      pixelsPerPoint: 1) { success in
                continuation.resume(returning: success)
            }
            if engine.render(offscreen: request) == false {
                continuation.resume(returning: nil)
            }
        }
        XCTAssertEqual(didComplete, true, "Offscreen frame must schedule and complete")

        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        pixels.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!,
                             bytesPerRow: size * 4,
                             from: MTLRegionMake2D(0, 0, size, size),
                             mipmapLevel: 0)
        }
        return pixels
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

private final class StubRouteSource: RouteRenderSource {
    var currentRoutesController: ImmersiveMapRoutesController? { nil }
}
