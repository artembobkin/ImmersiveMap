// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import QuartzCore
import XCTest

/// Renders headless frames through `RenderFrameEngine.render(offscreen:)` into
/// a plain BGRA texture. Requires the compiled Metal library, so it skips
/// under `swift test` and runs in the xcodebuild workspace suite.
final class RenderFrameOffscreenTargetTests: XCTestCase {
    private final class StubAvatarSource: AvatarRenderSource {
        var currentAvatarController: ImmersiveMapAvatarsController? { nil }
    }

    private final class StubMarkerSource: MarkerRenderSource {
        var currentMarkerProjectionInput: MarkerProjectionInput { .empty }
    }

    private final class StubSceneModelSource: SceneModelRenderSource {
        var currentSceneModelsController: ImmersiveMapSceneModelsController? { nil }
    }

    @MainActor
    func testOffscreenRenderSchedulesCompletesAndWritesPixels() async throws {
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
        let eventSink = VideoExportRenderEventSink()
        let renderCamera = FrameCameraStateResolver(settings: settings)
        let presentation = MapPresentationStateController(settings: settings)
        let layer = CAMetalLayer()
        let engine = RenderFrameEngine(layer: layer,
                                       avatarSource: StubAvatarSource(),
                                       markerSource: StubMarkerSource(),
                                       sceneModelSource: StubSceneModelSource(),
                                       providerRuntime: ImmersiveMapProviderRuntimeContext(settings: settings),
                                       settings: settings,
                                       renderCamera: renderCamera,
                                       presentationStateResolver: presentation,
                                       eventSink: eventSink,
                                       tileTraceRecorder: TileTraceRecorder(),
                                       baseLabelTraceRecorder: BaseLabelTraceRecorder(),
                                       clock: clock)
        let device = try XCTUnwrap(layer.device)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: 64,
                                                                  height: 64,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))

        for frameIndex in 0..<2 {
            clock.setTime(TimeInterval(frameIndex) / 60.0)
            let didComplete = await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
                let request = RenderFrameOffscreenRequest(texture: texture,
                                                          drawSize: CGSize(width: 64, height: 64)) { success in
                    continuation.resume(returning: success)
                }
                if engine.render(offscreen: request) == false {
                    continuation.resume(returning: nil)
                }
            }
            XCTAssertEqual(didComplete, true, "Offscreen frame \(frameIndex) must schedule and complete")
        }

        var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
        pixels.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!,
                             bytesPerRow: 64 * 4,
                             from: MTLRegionMake2D(0, 0, 64, 64),
                             mipmapLevel: 0)
        }
        // The world pass clears with an opaque background, so at minimum every
        // alpha byte is 255.
        XCTAssertTrue(pixels.contains { $0 != 0 }, "Rendered texture must not be all zero")
    }
}
