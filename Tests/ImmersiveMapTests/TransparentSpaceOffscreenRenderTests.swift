// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// End-to-end: with transparent space a headless frame must come back with the
/// area outside the globe unpainted while everything drawn on the globe keeps
/// its own coverage. A headless frame has no tiles, so the globe is its
/// placeholder fill, shaded by the night side at the scripted clock's date, and
/// a route arc stands in for the content on the globe. Requires the compiled
/// Metal library, so it skips under `swift test` and runs in the xcodebuild
/// workspace suite.
final class TransparentSpaceOffscreenRenderTests: XCTestCase {
    /// The earth scene is on with its Sun, which is the case that has to hold:
    /// the space background, the stars and the Sun all come from the starfield
    /// layer, so if any of them still painted, the corners would come back
    /// opaque.
    @MainActor
    func testTransparentSpaceLeavesTheAreaOutsideTheGlobeUnpainted() async throws {
        let settings = ImmersiveMapSettings.default
            .earthScene(isEnabled: true)
            .transparentSpace()
        XCTAssertTrue(settings.scene.earth.sun.isEnabled,
                      "The Sun must be on, otherwise this test proves nothing")
        let frame = try await renderFrame(settings: settings, routeAlpha: 1.0)

        for corner in frame.corners {
            XCTAssertEqual(corner.alpha, 0, "Nothing outside the globe may be painted")
        }
        XCTAssertGreaterThan(frame.count(where: isOpaqueRoutePixel), 0,
                             "What is drawn on the globe must stay opaque")
    }

    /// The default globe paints space, and that must not change.
    @MainActor
    func testOpaqueSpacePaintsTheWholeFrame() async throws {
        let frame = try await renderFrame(settings: .default, routeAlpha: 1.0)

        for corner in frame.corners {
            XCTAssertEqual(corner.alpha, 255)
        }
    }

    /// FXAA writes the drawable in its own pass, so it is the one place where a
    /// forced alpha of 1 would silently make the frame opaque again.
    @MainActor
    func testTransparentSpaceSurvivesPostProcessing() async throws {
        var settings = ImmersiveMapSettings.default.transparentSpace()
        settings.postProcessing = ImmersiveMapSettings.PostProcessingSettings(fxaaEnabled: true)
        let frame = try await renderFrame(settings: settings, routeAlpha: 1.0)

        for corner in frame.corners {
            XCTAssertEqual(corner.alpha, 0, "FXAA must carry the frame alpha through")
        }
        XCTAssertGreaterThan(frame.count(where: isOpaqueRoutePixel), 0)
    }

    /// Translucent content must land on the transparent frame with its own
    /// coverage: blending alpha with `.sourceAlpha` would square it, so a route
    /// at 50% would come back at 25% and read as washed out over the app's
    /// background.
    ///
    /// The arc is placed past the limb, over empty space. Over the globe the
    /// destination alpha is already 1 (the surface paints its placeholder fill
    /// under the tiles), so the route's own contribution is unmeasurable there
    /// and the check would pass whatever the blend factor is.
    @MainActor
    func testTranslucentContentKeepsItsCoverageOverTransparentSpace() async throws {
        let frame = try await renderFrame(settings: .default.transparentSpace(),
                                          routeAlpha: 0.5,
                                          routeBeyondTheLimb: true)

        let peak = try XCTUnwrap(peakRouteAlpha(in: frame), "The route must reach the frame")
        XCTAssertGreaterThanOrEqual(Int(peak), 120, "A 50% route must keep ~50% coverage, not 25%")
        XCTAssertLessThan(Int(peak), 200, "Over empty space the route cannot be more opaque than it is")
    }

    // MARK: - Helpers

    /// The map has no red anywhere in its default palette, so a red-dominated
    /// pixel can only come from the route.
    private func isRoutePixel(_ pixel: RenderedFrame.Pixel) -> Bool {
        pixel.red > 60 && pixel.green < 40 && pixel.blue < 40
    }

    /// Route pixels that came out fully opaque: content on the globe must keep
    /// its own coverage while the frame around it stays transparent.
    private func isOpaqueRoutePixel(_ pixel: RenderedFrame.Pixel) -> Bool {
        isRoutePixel(pixel) && pixel.alpha == 255
    }

    /// The strongest coverage the route reached, read at its centre line rather
    /// than averaged, so antialiased edges do not drag the measurement down.
    private func peakRouteAlpha(in frame: RenderedFrame) -> UInt8? {
        frame.allPixels.lazy.filter(isRoutePixel).map(\.alpha).max()
    }

    /// A wide arc centred on the camera, lifted well off the surface so it
    /// cannot be swallowed by the globe's own depth.
    ///
    /// `beyondTheLimb` moves it past the horizon and lifts it far enough to
    /// clear the planet anyway, which puts it over empty space rather than over
    /// the globe. That placement is what the coverage test needs: over the
    /// globe the destination is opaque, so the alpha the route contributes
    /// cannot be measured there at all.
    private func makeRoute(around center: ImmersiveMapCameraPosition,
                           alpha: Float,
                           beyondTheLimb: Bool) -> ImmersiveMapRoute {
        let path = beyondTheLimb
            ? ImmersiveMapGeoPath(
                from: GeoCoordinate(latitude: center.latitudeDegrees - 80,
                                    longitude: center.longitudeDegrees - 5),
                to: GeoCoordinate(latitude: center.latitudeDegrees - 80,
                                  longitude: center.longitudeDegrees + 5),
                baseAltitudeMeters: 2_500_000)
            : ImmersiveMapGeoPath(
                from: GeoCoordinate(latitude: center.latitudeDegrees,
                                    longitude: center.longitudeDegrees - 20),
                to: GeoCoordinate(latitude: center.latitudeDegrees,
                                  longitude: center.longitudeDegrees + 20),
                peakAltitudeMeters: 500_000)
        return ImmersiveMapRoute(id: 1,
                                 path: path,
                                 color: SIMD4<Float>(1, 0, 0, alpha),
                                 widthPoints: 6,
                                 progress: 1)
    }

    /// Renders one offscreen frame of a globe at zoom 1 with a single route
    /// across it.
    @MainActor
    private func renderFrame(settings: ImmersiveMapSettings,
                             routeAlpha: Float,
                             routeBeyondTheLimb: Bool = false) async throws -> RenderedFrame {
        let harness = try OffscreenFrameHarness.makeOrSkip(settings: settings)
        harness.setZoom(1.0)
        harness.routes.add(makeRoute(around: harness.cameraPosition,
                                     alpha: routeAlpha,
                                     beyondTheLimb: routeBeyondTheLimb))
        return try await harness.renderFrame()
    }
}
