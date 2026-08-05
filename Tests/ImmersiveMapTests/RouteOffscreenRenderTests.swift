// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Metal
import QuartzCore
import XCTest

/// End-to-end: a route across the visible face of the globe must paint its
/// colour into a headless frame, must not paint anything on the flat map, and
/// must respect `progress`. Requires the compiled Metal library, so it skips
/// under `swift test` and runs in the xcodebuild workspace suite.
final class RouteOffscreenRenderTests: XCTestCase {
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
    func testRouteOnTheGlobePaintsItsColour() async throws {
        let device = try makeDeviceOrSkip()
        let context = try makeContext(device: device, zoom: 1.0)

        let baseline = try await renderFrame(context: context, time: 0)
        context.routeSource.controller.add(makeRoute(around: context.renderCamera, progress: 1))
        let painted = try await renderFrame(context: context, time: 1.0 / 60.0)

        XCTAssertNotEqual(painted, baseline, "A route across the globe must change the frame")
        XCTAssertGreaterThan(redPixelCount(in: painted), 0,
                             "The route colour must reach the drawable")
    }

    /// Routes are a globe-only feature in this version, enforced by the layer
    /// plan rather than by a branch inside the subsystem.
    @MainActor
    func testRouteDrawsNothingOnTheFlatMap() async throws {
        let device = try makeDeviceOrSkip()
        let context = try makeContext(device: device, zoom: 15.0)

        let baseline = try await renderFrame(context: context, time: 0)
        context.routeSource.controller.add(makeRoute(around: context.renderCamera, progress: 1))
        let painted = try await renderFrame(context: context, time: 1.0 / 60.0)

        XCTAssertEqual(redPixelCount(in: painted), 0)
        XCTAssertEqual(painted, baseline)
    }

    @MainActor
    func testProgressShortensTheDrawnRibbon() async throws {
        let device = try makeDeviceOrSkip()
        let context = try makeContext(device: device, zoom: 1.0)
        _ = try await renderFrame(context: context, time: 0)

        context.routeSource.controller.add(makeRoute(around: context.renderCamera, progress: 1))
        let full = redPixelCount(in: try await renderFrame(context: context, time: 1.0 / 60.0))

        context.routeSource.controller.setProgress(id: 1, 0.25)
        let quarter = redPixelCount(in: try await renderFrame(context: context, time: 2.0 / 60.0))

        XCTAssertGreaterThan(full, 0)
        XCTAssertGreaterThan(quarter, 0)
        XCTAssertLessThan(quarter, full)
    }

    /// A dashed route must paint strictly fewer pixels than the same solid one
    /// while still covering the same stretch of globe.
    @MainActor
    func testDashLeavesGapsAlongTheLine() async throws {
        let device = try makeDeviceOrSkip()
        let context = try makeContext(device: device, zoom: 1.0)
        _ = try await renderFrame(context: context, time: 0)

        context.routeSource.controller.add(makeRoute(around: context.renderCamera, progress: 1))
        let solid = redPixelCount(in: try await renderFrame(context: context, time: 1.0 / 60.0))

        var dashed = makeRoute(around: context.renderCamera, progress: 1)
        dashed.dash = ImmersiveMapRouteDash(dashPoints: 6, gapPoints: 6)
        context.routeSource.controller.upsert([dashed])
        let dashedCount = redPixelCount(in: try await renderFrame(context: context, time: 2.0 / 60.0))

        XCTAssertGreaterThan(solid, 0)
        XCTAssertGreaterThan(dashedCount, 0, "A dashed route must still draw its dashes")
        XCTAssertLessThan(dashedCount, solid * 3 / 4, "A one-to-one dash must leave visible gaps")
    }

    /// A pattern whose gap is zero is a solid line, not a shimmering one.
    @MainActor
    func testDashWithoutAGapDrawsSolid() async throws {
        let device = try makeDeviceOrSkip()
        let context = try makeContext(device: device, zoom: 1.0)
        _ = try await renderFrame(context: context, time: 0)

        context.routeSource.controller.add(makeRoute(around: context.renderCamera, progress: 1))
        let solid = redPixelCount(in: try await renderFrame(context: context, time: 1.0 / 60.0))

        var degenerate = makeRoute(around: context.renderCamera, progress: 1)
        degenerate.dash = ImmersiveMapRouteDash(dashPoints: 6, gapPoints: 0)
        context.routeSource.controller.upsert([degenerate])
        let degenerateCount = redPixelCount(in: try await renderFrame(context: context, time: 2.0 / 60.0))

        XCTAssertEqual(degenerateCount, solid)
    }

    // MARK: - Helpers

    private struct Context {
        let engine: RenderFrameEngine
        let clock: RenderFrameScriptedClock
        let texture: MTLTexture
        let routeSource: StubRouteSource
        let renderCamera: FrameCameraStateResolver
    }

    @MainActor
    private func makeContext(device: MTLDevice, zoom: Double) throws -> Context {
        let settings = ImmersiveMapSettings.default
        let clock = RenderFrameScriptedClock()
        let routeSource = StubRouteSource()
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

        return Context(engine: engine,
                       clock: clock,
                       texture: texture,
                       routeSource: routeSource,
                       renderCamera: renderCamera)
    }

    /// A wide arc centred on the camera, lifted well off the surface so it
    /// cannot be swallowed by the globe's own depth.
    @MainActor
    private func makeRoute(around renderCamera: FrameCameraStateResolver,
                           progress: Double) -> ImmersiveMapRoute {
        let center = renderCamera.currentCameraPosition()
        let path = ImmersiveMapGeoPath(
            from: GeoCoordinate(latitude: center.latitudeDegrees, longitude: center.longitudeDegrees - 20),
            to: GeoCoordinate(latitude: center.latitudeDegrees, longitude: center.longitudeDegrees + 20),
            peakAltitudeMeters: 500_000)
        return ImmersiveMapRoute(id: 1,
                                 path: path,
                                 color: SIMD4<Float>(1, 0, 0, 1),
                                 widthPoints: 6,
                                 progress: progress)
    }

    /// The map has no red anywhere in its default palette, so a saturated red
    /// pixel can only come from the route.
    private func redPixelCount(in pixels: [UInt8]) -> Int {
        var count = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let blue = Int(pixels[index])
            let green = Int(pixels[index + 1])
            let red = Int(pixels[index + 2])
            if red > 150, green < 90, blue < 90 {
                count += 1
            }
        }
        return count
    }

    @MainActor
    private func renderFrame(context: Context, time: TimeInterval) async throws -> [UInt8] {
        context.clock.setTime(time)
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
