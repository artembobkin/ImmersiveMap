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

    // MARK: - Horizon

    /// A ribbon on the far hemisphere must not reach the drawable at all.
    ///
    /// Two mechanisms cover this one deep in the far side: the shader gate and
    /// the depth the surface writes. It therefore stays green with the gate
    /// removed, and it is here for the behaviour, not as coverage of the gate.
    /// The cases the gate alone answers, where the depth buffer is incomplete,
    /// are the limb, the polar caps and the tilted horizon below.
    @MainActor
    func testRouteOnTheFarSideOfTheGlobeIsNotDrawn() async throws {
        let device = try makeDeviceOrSkip()
        let context = try makeContext(device: device, zoom: 1.0, settings: Self.flatlitSettings)
        _ = try await renderFrame(context: context, time: 0)
        let center = context.renderCamera.currentCameraPosition()

        context.routeSource.controller.add(makeRoute(
            latitude: -center.latitudeDegrees,
            longitude: center.longitudeDegrees + 180,
            halfSpanDegrees: 20))
        let painted = try await renderFrame(context: context, time: 1.0 / 60.0)

        XCTAssertEqual(redPixelCount(in: painted), 0)
    }

    /// Just past the horizon (the visible cap ends at 77.4 degrees from the
    /// camera at this zoom) the ribbon used to survive the depth test and paint
    /// over the rim of the globe, which is exactly where a viewer reads it as
    /// "the path is on the other side, why can I see it".
    @MainActor
    func testGroundRouteBeyondTheHorizonDoesNotSpillOverTheLimb() async throws {
        let device = try makeDeviceOrSkip()
        let context = try makeContext(device: device, zoom: 1.0, settings: Self.flatlitSettings)
        _ = try await renderFrame(context: context, time: 0)
        let center = context.renderCamera.currentCameraPosition()

        context.routeSource.controller.add(makeRoute(
            latitude: center.latitudeDegrees - 80,
            longitude: center.longitudeDegrees,
            halfSpanDegrees: 5))
        let painted = try await renderFrame(context: context, time: 1.0 / 60.0)

        XCTAssertEqual(redPixelCount(in: painted), 0)
    }

    /// The gate tests the point where it actually is, altitude included, so an
    /// arc that climbs away from the planet clears the horizon plane on its own
    /// and keeps flying past the limb. Same geometry as the test above, lifted
    /// far enough to rise over it: at 80 degrees from the camera the horizon
    /// plane sits at roughly 2000 km of altitude, so this is the same ribbon
    /// with only the altitude profile changed.
    @MainActor
    func testLiftedArcStaysVisibleBeyondTheHorizon() async throws {
        let device = try makeDeviceOrSkip()
        let context = try makeContext(device: device, zoom: 1.0, settings: Self.flatlitSettings)
        _ = try await renderFrame(context: context, time: 0)
        let center = context.renderCamera.currentCameraPosition()

        context.routeSource.controller.add(makeRoute(
            latitude: center.latitudeDegrees - 80,
            longitude: center.longitudeDegrees,
            halfSpanDegrees: 5,
            baseAltitudeMeters: 2_500_000))
        let painted = try await renderFrame(context: context, time: 1.0 / 60.0)

        XCTAssertGreaterThan(redPixelCount(in: painted), 0)
    }

    /// The shadow a sphere casts is a cone, not a half space. This ribbon sits
    /// past the plane through the tangent circle (101 degrees from the camera,
    /// where a point on the surface is long hidden) but its altitude carries it
    /// out of the cone, so the line of sight reaches it and it must paint.
    /// A plane test passes every other case here and fails only this one.
    @MainActor
    func testLiftedArcOutsideTheShadowConeStillPaints() async throws {
        let device = try makeDeviceOrSkip()
        let context = try makeContext(device: device, zoom: 1.0, settings: Self.flatlitSettings)
        _ = try await renderFrame(context: context, time: 0)
        let center = context.renderCamera.currentCameraPosition()

        context.routeSource.controller.add(makeRoute(
            latitude: center.latitudeDegrees - 101,
            longitude: center.longitudeDegrees,
            halfSpanDegrees: 5,
            baseAltitudeMeters: 600_000))
        let painted = try await renderFrame(context: context, time: 1.0 / 60.0)

        XCTAssertGreaterThan(redPixelCount(in: painted), 0)
    }

    /// The polar caps draw without depth writes, and the placeholder fill under
    /// the tiles stops at the Mercator limit of 85.05 degrees, so the depth
    /// buffer has a hole exactly over each pole. A ground track on the far side
    /// whose line of sight leaves the globe through that hole is what used to
    /// paint a red arc across the Arctic, and only the shader gate stops it:
    /// remove the gate and this test paints again.
    @MainActor
    func testFarSideRouteDoesNotLeakThroughThePolarCap() async throws {
        let device = try makeDeviceOrSkip()
        let context = try makeContext(device: device, zoom: 1.0, settings: Self.flatlitSettings)
        _ = try await renderFrame(context: context, time: 0)
        let center = context.renderCamera.currentCameraPosition()

        context.routeSource.controller.add(makeRoute(
            latitude: 0,
            longitude: center.longitudeDegrees + 180,
            halfSpanDegrees: 30))
        let painted = try await renderFrame(context: context, time: 1.0 / 60.0)

        XCTAssertEqual(redPixelCount(in: painted), 0)
    }

    /// The control for all three: the same short ribbon on the visible face
    /// paints, so a zero above means "gated", not "never drawn".
    @MainActor
    func testShortRouteOnTheVisibleFacePaints() async throws {
        let device = try makeDeviceOrSkip()
        let context = try makeContext(device: device, zoom: 1.0, settings: Self.flatlitSettings)
        _ = try await renderFrame(context: context, time: 0)
        let center = context.renderCamera.currentCameraPosition()

        context.routeSource.controller.add(makeRoute(latitude: center.latitudeDegrees,
                                                     longitude: center.longitudeDegrees,
                                                     halfSpanDegrees: 5))
        let painted = try await renderFrame(context: context, time: 1.0 / 60.0)

        XCTAssertGreaterThan(redPixelCount(in: painted), 0)
    }

    /// Tilt swings the eye off the axis (pitch rotates it about +x, so it moves
    /// towards -y while the view stays on the point under it) and brings it
    /// closer to the planet's center, which pulls the far horizon in: looking
    /// north from 55.8N at the pitch limit, the surface runs out around 15
    /// degrees of latitude ahead instead of the 47 it reaches head on.
    ///
    /// Both tracks here are chosen to be **inside the frustum** (`w` of 1.23 and
    /// 0.94), which is the whole point: a track picked on the near side is
    /// clipped for being behind the camera, and then the test reads zero no
    /// matter what the horizon gate does. The pair differs only in being past
    /// the horizon or short of it, so the zero can only come from the gate.
    @MainActor
    func testHorizonHoldsUnderCameraTilt() async throws {
        let device = try makeDeviceOrSkip()
        // Pitch is released with zoom on the globe (globePitchUnlockZoom), so
        // the tilt only reaches its limit past that zoom.
        let context = try makeContext(device: device,
                                      zoom: 3.5,
                                      settings: Self.flatlitSettings,
                                      pitch: ImmersiveMapSettings.default.camera.maximumPitch)
        _ = try await renderFrame(context: context, time: 0)
        let center = context.renderCamera.currentCameraPosition()
        XCTAssertGreaterThan(center.pitch, 0.5, "The camera must actually be tilted")

        context.routeSource.controller.add(makeRoute(latitude: center.latitudeDegrees + 17,
                                                     longitude: center.longitudeDegrees,
                                                     halfSpanDegrees: 5))
        let beyondHorizon = try await renderFrame(context: context, time: 1.0 / 60.0)
        XCTAssertEqual(redPixelCount(in: beyondHorizon), 0,
                       "A tilted camera must not see a ground track beyond its horizon")

        context.routeSource.controller.clear()
        context.routeSource.controller.add(makeRoute(latitude: center.latitudeDegrees + 10,
                                                     longitude: center.longitudeDegrees,
                                                     halfSpanDegrees: 5))
        let shortOfTheHorizon = try await renderFrame(context: context, time: 2.0 / 60.0)
        XCTAssertGreaterThan(redPixelCount(in: shortOfTheHorizon), 0,
                             "The same track short of that horizon must paint")
    }

    // MARK: - Helpers

    /// Flat lighting for the horizon tests: the terminator would sink a red
    /// ribbon into the night side, and the Sun's glow reads as red pixels.
    private static let flatlitSettings = ImmersiveMapSettings.default.earthScene(isEnabled: false)

    /// A short ground ribbon centred on one coordinate, so a test states the
    /// angular distance from the camera it wants and nothing else.
    private func makeRoute(latitude: Double,
                           longitude: Double,
                           halfSpanDegrees: Double,
                           baseAltitudeMeters: Double = 0) -> ImmersiveMapRoute {
        let path = ImmersiveMapGeoPath(
            from: GeoCoordinate(latitude: latitude, longitude: longitude - halfSpanDegrees),
            to: GeoCoordinate(latitude: latitude, longitude: longitude + halfSpanDegrees),
            baseAltitudeMeters: baseAltitudeMeters)
        return ImmersiveMapRoute(id: 1,
                                 path: path,
                                 color: SIMD4<Float>(1, 0, 0, 1),
                                 widthPoints: 6,
                                 progress: 1)
    }

    private struct Context {
        let engine: RenderFrameEngine
        let clock: RenderFrameScriptedClock
        let texture: MTLTexture
        let routeSource: StubRouteSource
        let renderCamera: FrameCameraStateResolver
    }

    @MainActor
    private func makeContext(device: MTLDevice,
                             zoom: Double,
                             settings: ImmersiveMapSettings = .default,
                             pitch: Float = 0) throws -> Context {
        let clock = RenderFrameScriptedClock()
        let routeSource = StubRouteSource()
        let renderCamera = FrameCameraStateResolver(settings: settings)
        let start = renderCamera.currentCameraPosition()
        renderCamera.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: start.latitudeDegrees,
                                                                  longitudeDegrees: start.longitudeDegrees,
                                                                  zoom: zoom,
                                                                  pitch: pitch))
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
