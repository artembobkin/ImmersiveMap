// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The globe surface drawn from tile geometry: a fixture tile's colour must
/// reach the sphere through the sphere tile pipeline, lit by the shared
/// globe surface shading. Requires the compiled Metal library, so it skips
/// under `swift test` and runs in the xcodebuild workspace suite.
final class GlobeVectorSurfaceOffscreenRenderTests: XCTestCase {
    /// A colour that appears nowhere else in the map.
    private static let fixtureWater = SIMD4<Float>(1, 0, 1, 1)
    private static let latitude = 55.75
    private static let longitude = 37.61

    /// Zoom 2.5 is spherical (the transition starts at 6) and past the tone
    /// deepening (over by zoom 2); face-on the atmosphere glow is zero and
    /// the fog strength is the transition, zero: the tile colour comes out
    /// exactly as given.
    @MainActor
    func testFixtureTileReachesTheSphereUnshaded() async throws {
        let harness = try makeHarness()
        harness.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: Self.latitude,
                                                              longitudeDegrees: Self.longitude,
                                                              zoom: 2.5))
        let baseline = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(0))
        XCTAssertEqual(baseline.count(where: isFixtureWater), 0,
                       "Nothing may be this colour before the fixture tile is loaded")

        try await loadFixtureTiles(into: harness, maximumZoom: 3)
        let painted = try await harness.renderUntilSettled(changedFrom: baseline,
                                                            startingAt: OffscreenFrameHarness.frameTime(1))
        let center = painted.center
        XCTAssertEqual(center.red, 255, "The water fixture must reach the centre of the sphere")
        XCTAssertEqual(center.green, 0)
        XCTAssertEqual(center.blue, 255)
        XCTAssertGreaterThan(painted.count(where: isFixtureWater), painted.size * painted.size / 8,
                             "A full-coverage water tile paints a large part of the visible disc")
        XCTAssertGreaterThan(harness.engine.currentDiagnostics?.counterValue(.renderedTiles) ?? 0, 0)
    }

    /// At zoom 1 the surface tone deepens the colour: the sphere path must
    /// shade through the same globe surface shading as the placeholder
    /// grid, so magenta comes out deepened, not raw.
    @MainActor
    func testSphereSurfaceIsShadedLikeTheGlobe() async throws {
        let harness = try makeHarness()
        harness.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: Self.latitude,
                                                              longitudeDegrees: Self.longitude,
                                                              zoom: 1.0))
        let baseline = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(0))
        try await loadFixtureTiles(into: harness, maximumZoom: 2)
        let painted = try await harness.renderUntilSettled(changedFrom: baseline,
                                                            startingAt: OffscreenFrameHarness.frameTime(1))
        let center = painted.center
        XCTAssertGreaterThan(center.red, 200)
        XCTAssertLessThan(center.red, 250, "The deepening must have applied to the fixture colour")
        XCTAssertLessThan(center.green, 40)
        XCTAssertGreaterThan(center.blue, 200)
        XCTAssertLessThan(center.blue, 250)
    }

    /// The geometry must clear the placeholder grid's depth everywhere, not
    /// only at its own vertices: a water polygon split on the parser's grid
    /// is a lattice of chords, and where a chord dipped below the placeholder
    /// the water failed the depth test in a diamond around each cell centre,
    /// showing the layer under it (a lattice of pale diamonds across the
    /// equatorial Atlantic, largest where the Mercator cells are largest).
    /// So: with the camera on the equator at zoom 2, a wide disc around the
    /// centre must be the water colour in every pixel.
    @MainActor
    func testWaterCoversTheDiscWithoutTheLayerBelowShowingThrough() async throws {
        let harness = try makeHarness(size: 512)
        harness.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: 0,
                                                              longitudeDegrees: 0,
                                                              zoom: 2.0))
        let baseline = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(0))
        try await loadFixtureTiles(into: harness, latitude: 0, longitude: 0, maximumZoom: 3)
        let painted = try await harness.renderUntilSettled(changedFrom: baseline,
                                                            startingAt: OffscreenFrameHarness.frameTime(1))

        // The disc: from the centre out to where the water is still the
        // colour it was given (the limb glow and the tone deepening are
        // gentle this far from the edge). Its radius is the widest run of
        // water-coloured pixels along the centre row, cut back by a third.
        let center = painted.size / 2
        var reach = 0
        while center + reach + 1 < painted.size, isWaterLike(painted.pixel(x: center + reach + 1, y: center)) {
            reach += 1
        }
        XCTAssertGreaterThan(reach, painted.size / 8, "The water must cover the middle of the frame")
        let radius = reach * 2 / 3
        var offColour = 0
        var checked = 0
        for y in (center - radius) ... (center + radius) {
            for x in (center - radius) ... (center + radius)
            where (x - center) * (x - center) + (y - center) * (y - center) <= radius * radius {
                checked += 1
                if isWaterLike(painted.pixel(x: x, y: y)) == false {
                    offColour += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 1000)
        XCTAssertEqual(offColour, 0, "\(offColour) of \(checked) pixels of the water disc show another colour")
    }

    // MARK: - Helpers

    @MainActor
    private func makeHarness(size: Int = 160) throws -> OffscreenFrameHarness {
        // Below the street palette the style paints water with the global
        // landcover blue and only eases toward `layers.water` as the camera
        // zooms in (the street palette blend is zero at these zooms), so the
        // colour this test owns is the overview one.
        let configuration = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault
            .globalLandcover { $0.water = Self.fixtureWater }
        var settings = ImmersiveMapSettings.default
            .earthScene(isEnabled: false)
            .mapStyle(ImmersiveMapTilesMapStyle(configuration: configuration))
        // The stars twinkle with scene time, so a settle loop over a globe
        // frame never sees two identical pictures while they are drawn.
        settings.scene.starfield.starCount = 0
        return try OffscreenFrameHarness.makeOrSkip(settings: settings, size: size)
    }

    @MainActor
    private func loadFixtureTiles(into harness: OffscreenFrameHarness,
                                  latitude: Double = GlobeVectorSurfaceOffscreenRenderTests.latitude,
                                  longitude: Double = GlobeVectorSurfaceOffscreenRenderTests.longitude,
                                  maximumZoom: Int) async throws {
        let data = VectorTileFixture.fullCoverageTile(layerName: "water", properties: ["class": "ocean"])
        let tiles = WebMercatorTileScheme.neighbourhoodPyramid(latitude: latitude,
                                                               longitude: longitude,
                                                               maximumZoom: maximumZoom)
        for tile in tiles {
            let didMaterialize = await harness.tileRenderStore.parseTile(tile: tile, data: data)
            XCTAssertTrue(didMaterialize, "Fixture tile \(tile.z)/\(tile.x)/\(tile.y) must parse")
        }
    }

    private func isFixtureWater(_ pixel: RenderedFrame.Pixel) -> Bool {
        pixel.red == 255 && pixel.green == 0 && pixel.blue == 255
    }

    /// The fixture colour through the globe shading (deepening, glow) but
    /// nothing else: the placeholder blue and the land under the water both
    /// carry far more green.
    private func isWaterLike(_ pixel: RenderedFrame.Pixel) -> Bool {
        pixel.red > 150 && pixel.green < 60 && pixel.blue > 150
    }
}
