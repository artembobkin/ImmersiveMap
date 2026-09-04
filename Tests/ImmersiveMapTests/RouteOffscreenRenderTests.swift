// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// End-to-end: a route across the visible face of the globe must paint its
/// colour into a headless frame, must not paint anything on the flat map, and
/// must respect `progress`. Requires the compiled Metal library, so it skips
/// under `swift test` and runs in the xcodebuild workspace suite.
final class RouteOffscreenRenderTests: XCTestCase {
    @MainActor
    func testRouteOnTheGlobePaintsItsColour() async throws {
        let harness = try makeHarness(zoom: 1.0)

        let baseline = try await harness.renderFrame(at: frameTime(0))
        harness.routes.add(makeArc(around: harness.cameraPosition, progress: 1))
        let painted = try await harness.renderFrame(at: frameTime(1))

        XCTAssertNotEqual(painted, baseline, "A route across the globe must change the frame")
        XCTAssertGreaterThan(painted.count(where: isRedPixel),
                             0,
                             "The route colour must reach the drawable")
    }

    /// Routes are a globe-only feature in this version, enforced by the layer
    /// plan rather than by a branch inside the subsystem.
    @MainActor
    func testRouteDrawsNothingOnTheFlatMap() async throws {
        let harness = try makeHarness(zoom: 15.0)

        let baseline = try await harness.renderFrame(at: frameTime(0))
        harness.routes.add(makeArc(around: harness.cameraPosition, progress: 1))
        let painted = try await harness.renderFrame(at: frameTime(1))

        XCTAssertEqual(painted.count(where: isRedPixel), 0)
        XCTAssertEqual(painted, baseline)
    }

    @MainActor
    func testProgressShortensTheDrawnRibbon() async throws {
        let harness = try makeHarness(zoom: 1.0)
        _ = try await harness.renderFrame(at: frameTime(0))

        harness.routes.add(makeArc(around: harness.cameraPosition, progress: 1))
        let full = try await harness.renderFrame(at: frameTime(1)).count(where: isRedPixel)

        harness.routes.setProgress(id: 1, 0.25)
        let quarter = try await harness.renderFrame(at: frameTime(2)).count(where: isRedPixel)

        XCTAssertGreaterThan(full, 0)
        XCTAssertGreaterThan(quarter, 0)
        XCTAssertLessThan(quarter, full)
    }

    /// A dashed route must paint strictly fewer pixels than the same solid one
    /// while still covering the same stretch of globe.
    @MainActor
    func testDashLeavesGapsAlongTheLine() async throws {
        let harness = try makeHarness(zoom: 1.0)
        _ = try await harness.renderFrame(at: frameTime(0))

        harness.routes.add(makeArc(around: harness.cameraPosition, progress: 1))
        let solid = try await harness.renderFrame(at: frameTime(1)).count(where: isRedPixel)

        var dashed = makeArc(around: harness.cameraPosition, progress: 1)
        dashed.dash = ImmersiveMapRouteDash(dashPoints: 6, gapPoints: 6)
        harness.routes.upsert([dashed])
        let dashedCount = try await harness.renderFrame(at: frameTime(2)).count(where: isRedPixel)

        XCTAssertGreaterThan(solid, 0)
        XCTAssertGreaterThan(dashedCount, 0, "A dashed route must still draw its dashes")
        XCTAssertLessThan(dashedCount, solid * 3 / 4, "A one-to-one dash must leave visible gaps")
    }

    /// A pattern whose gap is zero is a solid line, not a shimmering one.
    ///
    /// Compared within a tolerance rather than exactly. The dash shader
    /// computes coverage per segment, so a zero gap still evaluates a boundary
    /// at every dash edge and antialiasing there rounds a handful of pixels
    /// differently from an unpatterned line. CI caught this at 155 against
    /// 159: visually the same line, four pixels apart. The claim worth making
    /// is that no gaps opened up, and a gap of any size would remove far more
    /// than a few percent.
    @MainActor
    func testDashWithoutAGapDrawsSolid() async throws {
        let harness = try makeHarness(zoom: 1.0)
        _ = try await harness.renderFrame(at: frameTime(0))

        harness.routes.add(makeArc(around: harness.cameraPosition, progress: 1))
        let solid = try await harness.renderFrame(at: frameTime(1)).count(where: isRedPixel)

        var degenerate = makeArc(around: harness.cameraPosition, progress: 1)
        degenerate.dash = ImmersiveMapRouteDash(dashPoints: 6, gapPoints: 0)
        harness.routes.upsert([degenerate])
        let degenerateCount = try await harness.renderFrame(at: frameTime(2)).count(where: isRedPixel)

        XCTAssertGreaterThan(solid, 0)
        XCTAssertEqual(Double(degenerateCount), Double(solid), accuracy: Double(solid) * 0.05,
                       "A zero gap must leave the line whole, give or take the dash edges")
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
        let harness = try makeHarness(zoom: 1.0, settings: Self.flatlitSettings)
        _ = try await harness.renderFrame(at: frameTime(0))
        let center = harness.cameraPosition

        harness.routes.add(makeRoute(latitude: -center.latitudeDegrees,
                                     longitude: center.longitudeDegrees + 180,
                                     halfSpanDegrees: 20))
        let painted = try await harness.renderFrame(at: frameTime(1))

        XCTAssertEqual(painted.count(where: isRedPixel), 0)
    }

    /// Just past the horizon (the visible cap ends at 77.4 degrees from the
    /// camera at this zoom) the ribbon used to survive the depth test and paint
    /// over the rim of the globe, which is exactly where a viewer reads it as
    /// "the path is on the other side, why can I see it".
    @MainActor
    func testGroundRouteBeyondTheHorizonDoesNotSpillOverTheLimb() async throws {
        let harness = try makeHarness(zoom: 1.0, settings: Self.flatlitSettings)
        _ = try await harness.renderFrame(at: frameTime(0))
        let center = harness.cameraPosition

        harness.routes.add(makeRoute(latitude: center.latitudeDegrees - 80,
                                     longitude: center.longitudeDegrees,
                                     halfSpanDegrees: 5))
        let painted = try await harness.renderFrame(at: frameTime(1))

        XCTAssertEqual(painted.count(where: isRedPixel), 0)
    }

    /// The gate tests the point where it actually is, altitude included, so an
    /// arc that climbs away from the planet clears the horizon plane on its own
    /// and keeps flying past the limb. Same geometry as the test above, lifted
    /// far enough to rise over it: at 80 degrees from the camera the horizon
    /// plane sits at roughly 2000 km of altitude, so this is the same ribbon
    /// with only the altitude profile changed.
    @MainActor
    func testLiftedArcStaysVisibleBeyondTheHorizon() async throws {
        let harness = try makeHarness(zoom: 1.0, settings: Self.flatlitSettings)
        _ = try await harness.renderFrame(at: frameTime(0))
        let center = harness.cameraPosition

        harness.routes.add(makeRoute(latitude: center.latitudeDegrees - 80,
                                     longitude: center.longitudeDegrees,
                                     halfSpanDegrees: 5,
                                     baseAltitudeMeters: 2_500_000))
        let painted = try await harness.renderFrame(at: frameTime(1))

        XCTAssertGreaterThan(painted.count(where: isRedPixel), 0)
    }

    /// The shadow a sphere casts is a cone, not a half space. This ribbon sits
    /// past the plane through the tangent circle (101 degrees from the camera,
    /// where a point on the surface is long hidden) but its altitude carries it
    /// out of the cone, so the line of sight reaches it and it must paint.
    /// A plane test passes every other case here and fails only this one.
    @MainActor
    func testLiftedArcOutsideTheShadowConeStillPaints() async throws {
        let harness = try makeHarness(zoom: 1.0, settings: Self.flatlitSettings)
        _ = try await harness.renderFrame(at: frameTime(0))
        let center = harness.cameraPosition

        harness.routes.add(makeRoute(latitude: center.latitudeDegrees - 101,
                                     longitude: center.longitudeDegrees,
                                     halfSpanDegrees: 5,
                                     baseAltitudeMeters: 600_000))
        let painted = try await harness.renderFrame(at: frameTime(1))

        XCTAssertGreaterThan(painted.count(where: isRedPixel), 0)
    }

    /// The polar caps draw without depth writes, and the placeholder fill under
    /// the tiles stops at the Mercator limit of 85.05 degrees, so the depth
    /// buffer has a hole exactly over each pole. A ground track on the far side
    /// whose line of sight leaves the globe through that hole is what used to
    /// paint a red arc across the Arctic, and only the shader gate stops it:
    /// remove the gate and this test paints again.
    @MainActor
    func testFarSideRouteDoesNotLeakThroughThePolarCap() async throws {
        let harness = try makeHarness(zoom: 1.0, settings: Self.flatlitSettings)
        _ = try await harness.renderFrame(at: frameTime(0))
        let center = harness.cameraPosition

        harness.routes.add(makeRoute(latitude: 0,
                                     longitude: center.longitudeDegrees + 180,
                                     halfSpanDegrees: 30))
        let painted = try await harness.renderFrame(at: frameTime(1))

        XCTAssertEqual(painted.count(where: isRedPixel), 0)
    }

    /// The control for all three: the same short ribbon on the visible face
    /// paints, so a zero above means "gated", not "never drawn".
    @MainActor
    func testShortRouteOnTheVisibleFacePaints() async throws {
        let harness = try makeHarness(zoom: 1.0, settings: Self.flatlitSettings)
        _ = try await harness.renderFrame(at: frameTime(0))
        let center = harness.cameraPosition

        harness.routes.add(makeRoute(latitude: center.latitudeDegrees,
                                     longitude: center.longitudeDegrees,
                                     halfSpanDegrees: 5))
        let painted = try await harness.renderFrame(at: frameTime(1))

        XCTAssertGreaterThan(painted.count(where: isRedPixel), 0)
    }

    /// Tilt swings the eye off the axis (pitch rotates it about +x, so it moves
    /// towards -y while the view stays on the point under it) and brings it
    /// closer to the planet's center, which pulls the far horizon in: looking
    /// north from 55.8N at the pitch limit, the surface runs out 12.85 degrees
    /// of latitude ahead instead of the 53.2 it reaches head on at this zoom.
    ///
    /// Both tracks here are chosen to be **inside the frustum** (`w` of 1.08 and
    /// 0.94), which is the whole point: a track picked on the near side is
    /// clipped for being behind the camera, and then the test reads zero no
    /// matter what the horizon gate does. The pair differs only in being past
    /// the horizon or short of it, so the zero can only come from the gate.
    ///
    /// What survives the gate's removal at `+17` is the couple of pixels of
    /// ribbon that clear the limb, so a smaller `widthPoints` here would quietly
    /// turn this back into a test that cannot fail.
    @MainActor
    func testHorizonHoldsUnderCameraTilt() async throws {
        // Pitch is released with zoom on the globe (globePitchUnlockZoom), so
        // the tilt only reaches its limit past that zoom.
        let harness = try makeHarness(zoom: 3.5,
                                      settings: Self.flatlitSettings,
                                      pitch: ImmersiveMapSettings.default.camera.maximumPitch)
        _ = try await harness.renderFrame(at: frameTime(0))
        let center = harness.cameraPosition
        XCTAssertGreaterThan(center.pitch, 0.5, "The camera must actually be tilted")

        harness.routes.add(makeRoute(latitude: center.latitudeDegrees + 17,
                                     longitude: center.longitudeDegrees,
                                     halfSpanDegrees: 5))
        let beyondHorizon = try await harness.renderFrame(at: frameTime(1))
        XCTAssertEqual(beyondHorizon.count(where: isRedPixel), 0,
                       "A tilted camera must not see a ground track beyond its horizon")

        harness.routes.clear()
        harness.routes.add(makeRoute(latitude: center.latitudeDegrees + 10,
                                     longitude: center.longitudeDegrees,
                                     halfSpanDegrees: 5))
        let shortOfTheHorizon = try await harness.renderFrame(at: frameTime(2))
        XCTAssertGreaterThan(shortOfTheHorizon.count(where: isRedPixel), 0,
                             "The same track short of that horizon must paint")
    }

    // MARK: - Helpers

    /// No air for the horizon tests: the atmosphere's rim over the surface
    /// saturates right at the limb, so a ribbon that clears the horizon by
    /// a couple of pixels would dissolve into it and read as no ribbon at
    /// all. The limb feather stays (it is not optional) and is thin enough
    /// to leave the ribbon's red.
    private static let flatlitSettings = ImmersiveMapSettings.default.atmosphere(isEnabled: false)

    @MainActor
    private func makeHarness(zoom: Double,
                             settings: ImmersiveMapSettings = .default,
                             pitch: Float = 0) throws -> OffscreenFrameHarness {
        let harness = try OffscreenFrameHarness.makeOrSkip(settings: settings)
        harness.setZoom(zoom, pitch: pitch)
        return harness
    }

    private func frameTime(_ index: Int) -> TimeInterval {
        OffscreenFrameHarness.frameTime(index)
    }

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

    /// A wide arc centred on the camera, lifted well off the surface so it
    /// cannot be swallowed by the globe's own depth.
    private func makeArc(around center: ImmersiveMapCameraPosition,
                         progress: Double) -> ImmersiveMapRoute {
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
    private func isRedPixel(_ pixel: RenderedFrame.Pixel) -> Bool {
        pixel.red > 150 && pixel.green < 90 && pixel.blue < 90
    }
}
