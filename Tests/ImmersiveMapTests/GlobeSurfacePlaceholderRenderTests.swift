// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import QuartzCore
import XCTest

/// The globe paints its own surface before any tile arrives, so the very first
/// frame shows a planet in the map's background color instead of a shell with
/// space showing through it. Requires the compiled Metal library, so it skips
/// under `swift test` and runs in the xcodebuild workspace suite.
final class GlobeSurfacePlaceholderRenderTests: XCTestCase {
    private final class StubAvatarSource: AvatarRenderSource {
        var currentAvatarController: ImmersiveMapAvatarsController? { nil }
    }

    private final class StubMarkerSource: MarkerRenderSource {
        var currentMarkerProjectionInput: MarkerProjectionInput { .empty }
    }

    private final class StubSceneModelSource: SceneModelRenderSource {
        var currentSceneModelsController: ImmersiveMapSceneModelsController? { nil }
    }

    private final class StubRouteSource: RouteRenderSource {
        var currentRoutesController: ImmersiveMapRoutesController? { nil }
    }

    private let size = 160

    @MainActor
    func testFirstGlobeFrameIsOpaqueBeforeAnyTileArrives() async throws {
        let device = try makeDeviceOrSkip()
        let context = try makeContext(device: device, zoom: 1.0)

        let frame = try await renderFrame(context: context)
        let center = pixel(in: frame, x: size / 2, y: size / 2)

        // The default map color is white, and the placeholder is the only thing
        // that can paint the middle of the globe on frame one. Alpha is part of
        // the claim: a fully transparent white pixel would satisfy every RGB
        // check while the planet still read as a hole into whatever is behind
        // the drawable.
        XCTAssertGreaterThan(Int(center.red), 200)
        XCTAssertGreaterThan(Int(center.green), 200)
        XCTAssertGreaterThan(Int(center.blue), 200)
        XCTAssertGreaterThan(Int(center.alpha), 200)
    }

    /// The fill follows the configured map color rather than being hardcoded
    /// white, so a dark style does not flash a white planet while it loads.
    @MainActor
    func testPlaceholderFollowsTheConfiguredMapColor() async throws {
        let device = try makeDeviceOrSkip()
        var settings = ImmersiveMapSettings.default.earthScene(isEnabled: false)
        settings.scene.mapClearColor = SIMD4<Double>(0.1, 0.2, 0.6, 1.0)
        let context = try makeContext(device: device, zoom: 1.0, settings: settings)

        let frame = try await renderFrame(context: context)
        let center = pixel(in: frame, x: size / 2, y: size / 2)

        XCTAssertGreaterThan(Int(center.blue), Int(center.red))
        XCTAssertGreaterThan(Int(center.blue), Int(center.green))
    }

    // MARK: - Helpers

    private struct Context {
        let engine: RenderFrameEngine
        let clock: RenderFrameScriptedClock
        let texture: MTLTexture
    }

    @MainActor
    private func makeContext(device: MTLDevice,
                             zoom: Double,
                             settings: ImmersiveMapSettings = .default.earthScene(isEnabled: false)) throws -> Context {
        let clock = RenderFrameScriptedClock()
        let renderCamera = FrameCameraStateResolver(settings: settings)
        let start = renderCamera.currentCameraPosition()
        renderCamera.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: start.latitudeDegrees,
                                                                  longitudeDegrees: start.longitudeDegrees,
                                                                  zoom: zoom))
        let layer = CAMetalLayer()
        let engine = RenderFrameEngine(layer: layer,
                                       avatarSource: StubAvatarSource(),
                                       markerSource: StubMarkerSource(),
                                       sceneModelSource: StubSceneModelSource(),
                                       routeSource: StubRouteSource(),
                                       providerRuntime: ImmersiveMapProviderRuntimeContext(settings: settings),
                                       settings: settings,
                                       renderCamera: renderCamera,
                                       presentationStateResolver: MapPresentationStateController(settings: settings),
                                       eventSink: VideoExportRenderEventSink(),
                                       tileTraceRecorder: TileTraceRecorder(),
                                       baseLabelTraceRecorder: BaseLabelTraceRecorder(),
                                       clock: clock)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                                  width: size,
                                                                  height: size,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(try XCTUnwrap(layer.device).makeTexture(descriptor: descriptor))

        return Context(engine: engine, clock: clock, texture: texture)
    }

    private func pixel(in pixels: [UInt8],
                       x: Int,
                       y: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        let index = (y * size + x) * 4
        return (pixels[index + 2], pixels[index + 1], pixels[index], pixels[index + 3])
    }

    @MainActor
    private func renderFrame(context: Context) async throws -> [UInt8] {
        context.clock.setTime(0)
        let didComplete = await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            let request = RenderFrameOffscreenRequest(texture: context.texture,
                                                      drawSize: CGSize(width: size, height: size),
                                                      pixelsPerPoint: 1) { success in
                continuation.resume(returning: success)
            }
            if context.engine.render(offscreen: request) == false {
                continuation.resume(returning: nil)
            }
        }
        XCTAssertEqual(didComplete, true, "Offscreen frame must schedule and complete")

        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        pixels.withUnsafeMutableBytes { buffer in
            context.texture.getBytes(buffer.baseAddress!,
                                     bytesPerRow: size * 4,
                                     from: MTLRegionMake2D(0, 0, size, size),
                                     mipmapLevel: 0)
        }
        return pixels
    }

    private func makeDeviceOrSkip() throws -> MTLDevice {
        guard let probeDevice = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        guard (try? probeDevice.makeDefaultLibrary(bundle: .module)) != nil else {
            throw XCTSkip("Compiled Metal library is unavailable in this test environment")
        }
        guard probeDevice.hasUnifiedMemory else {
            throw XCTSkip("Unified-memory GPU is required for direct texture readback")
        }
        return probeDevice
    }
}
