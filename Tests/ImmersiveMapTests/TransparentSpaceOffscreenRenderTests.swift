// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import QuartzCore
import XCTest

/// End-to-end: with transparent space a headless frame must come back with the
/// area outside the globe unpainted while everything drawn on the globe keeps
/// its own coverage. A headless frame has no tiles, so the globe surface
/// discards itself and a route arc stands in for the content on the globe.
/// Requires the compiled Metal library, so it skips under `swift test` and runs
/// in the xcodebuild workspace suite.
final class TransparentSpaceOffscreenRenderTests: XCTestCase {
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
        let controller = ImmersiveMapRoutesController()
        var currentRoutesController: ImmersiveMapRoutesController? { controller }
    }

    private let size = 160

    @MainActor
    func testTransparentSpaceLeavesTheAreaOutsideTheGlobeUnpainted() async throws {
        let device = try makeDeviceOrSkip()
        let pixels = try await renderFrame(device: device,
                                           settings: .default.transparentSpace(),
                                           routeAlpha: 1.0)

        for corner in cornerIndices() {
            XCTAssertEqual(alpha(in: pixels, at: corner), 0,
                           "Nothing outside the globe may be painted")
        }
        XCTAssertGreaterThan(opaqueRoutePixelCount(in: pixels), 0,
                             "What is drawn on the globe must stay opaque")
    }

    /// The default globe paints space, and that must not change.
    @MainActor
    func testOpaqueSpacePaintsTheWholeFrame() async throws {
        let device = try makeDeviceOrSkip()
        let pixels = try await renderFrame(device: device,
                                           settings: .default,
                                           routeAlpha: 1.0)

        for corner in cornerIndices() {
            XCTAssertEqual(alpha(in: pixels, at: corner), 255)
        }
    }

    /// FXAA writes the drawable in its own pass, so it is the one place where a
    /// forced alpha of 1 would silently make the frame opaque again.
    @MainActor
    func testTransparentSpaceSurvivesPostProcessing() async throws {
        let device = try makeDeviceOrSkip()
        var settings = ImmersiveMapSettings.default.transparentSpace()
        settings.postProcessing = ImmersiveMapSettings.PostProcessingSettings(fxaaEnabled: true)
        let pixels = try await renderFrame(device: device,
                                           settings: settings,
                                           routeAlpha: 1.0)

        for corner in cornerIndices() {
            XCTAssertEqual(alpha(in: pixels, at: corner), 0,
                           "FXAA must carry the frame alpha through")
        }
        XCTAssertGreaterThan(opaqueRoutePixelCount(in: pixels), 0)
    }

    /// Translucent content must land on the transparent frame with its own
    /// coverage: blending alpha with `.sourceAlpha` would square it, so a route
    /// at 50% would come back at 25% and read as washed out over the app's
    /// background.
    @MainActor
    func testTranslucentContentKeepsItsCoverageOverTransparentSpace() async throws {
        let device = try makeDeviceOrSkip()
        let pixels = try await renderFrame(device: device,
                                           settings: .default.transparentSpace(),
                                           routeAlpha: 0.5)

        let peak = try XCTUnwrap(peakRouteAlpha(in: pixels), "The route must reach the frame")
        XCTAssertGreaterThanOrEqual(Int(peak), 120, "A 50% route must keep ~50% coverage, not 25%")
    }

    // MARK: - Helpers

    private func cornerIndices() -> [Int] {
        [
            0,
            size - 1,
            size * (size - 1),
            size * size - 1
        ]
    }

    private func alpha(in pixels: [UInt8], at pixelIndex: Int) -> UInt8 {
        pixels[pixelIndex * 4 + 3]
    }

    /// The map has no red anywhere in its default palette, so a red-dominated
    /// pixel can only come from the route.
    private func isRoutePixel(in pixels: [UInt8], at byteIndex: Int) -> Bool {
        let blue = Int(pixels[byteIndex])
        let green = Int(pixels[byteIndex + 1])
        let red = Int(pixels[byteIndex + 2])
        return red > 60 && green < 40 && blue < 40
    }

    private func opaqueRoutePixelCount(in pixels: [UInt8]) -> Int {
        stride(from: 0, to: pixels.count, by: 4)
            .filter { isRoutePixel(in: pixels, at: $0) && pixels[$0 + 3] == 255 }
            .count
    }

    private func peakRouteAlpha(in pixels: [UInt8]) -> UInt8? {
        stride(from: 0, to: pixels.count, by: 4)
            .filter { isRoutePixel(in: pixels, at: $0) }
            .map { pixels[$0 + 3] }
            .max()
    }

    /// A wide arc centred on the camera, lifted well off the surface so it
    /// cannot be swallowed by the globe's own depth.
    @MainActor
    private func makeRoute(around renderCamera: FrameCameraStateResolver,
                           alpha: Float) -> ImmersiveMapRoute {
        let center = renderCamera.currentCameraPosition()
        let path = ImmersiveMapGeoPath(
            from: GeoCoordinate(latitude: center.latitudeDegrees, longitude: center.longitudeDegrees - 20),
            to: GeoCoordinate(latitude: center.latitudeDegrees, longitude: center.longitudeDegrees + 20),
            peakAltitudeMeters: 500_000)
        return ImmersiveMapRoute(id: 1,
                                 path: path,
                                 color: SIMD4<Float>(1, 0, 0, alpha),
                                 widthPoints: 6,
                                 progress: 1)
    }

    @MainActor
    private func renderFrame(device _: MTLDevice,
                             settings: ImmersiveMapSettings,
                             routeAlpha: Float) async throws -> [UInt8] {
        let clock = RenderFrameScriptedClock()
        let routeSource = StubRouteSource()
        let renderCamera = FrameCameraStateResolver(settings: settings)
        let start = renderCamera.currentCameraPosition()
        renderCamera.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: start.latitudeDegrees,
                                                                  longitudeDegrees: start.longitudeDegrees,
                                                                  zoom: 1.0))
        let layer = CAMetalLayer()
        let engine = RenderFrameEngine(layer: layer,
                                       avatarSource: StubAvatarSource(),
                                       markerSource: StubMarkerSource(),
                                       sceneModelSource: StubSceneModelSource(),
                                       routeSource: routeSource,
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

        routeSource.controller.add(makeRoute(around: renderCamera, alpha: routeAlpha))
        clock.setTime(0)
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
