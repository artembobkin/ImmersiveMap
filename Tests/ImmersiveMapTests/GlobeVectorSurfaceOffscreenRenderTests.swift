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
    /// The far side's colour: cyan, which no water, placeholder or fog can make.
    private static let fixtureForest = SIMD4<Float>(0, 1, 1, 1)
    private static let latitude = 55.75
    private static let longitude = 37.61

    /// Zoom 2.5 is spherical (the transition starts at 6) and past the tone
    /// deepening (over by zoom 2); face-on the sphere is bare and
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

    /// At zoom 1 the sphere path draws through the same globe surface
    /// shading as the placeholder grid: the fixture magenta must come
    /// through as magenta (the deep-space tone is gone; day/night and the
    /// limb glow are gentle at the centre of the disc).
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
        XCTAssertLessThan(center.green, 60)
        XCTAssertGreaterThan(center.blue, 200)
    }

    /// The geometry must paint over the placeholder grid everywhere, not
    /// only at its own vertices. When it was still depth-tested against the
    /// grid, a water polygon split on the parser's grid was a lattice of
    /// chords, and where a chord dipped below the placeholder the water
    /// failed the test in a diamond around each cell centre, showing the
    /// layer under it (a lattice of pale diamonds across the equatorial
    /// Atlantic, largest where the Mercator cells are largest). The geometry
    /// is not depth-tested any more; this pins that nothing brings the
    /// lattice back. So: with the camera on the equator at zoom 2, a wide
    /// disc around the centre must be the water colour in every pixel.
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

    /// Halfway through the unfurl the far side of the planet is placed (the
    /// CPU stops rejecting tiles by the horizon at transition > 0) and the
    /// horizon clip has relaxed; what removes it is the winding: every tile
    /// triangle is counter-clockwise in render space, the far side is
    /// clockwise on screen, and the drawer culls back faces. Without that the
    /// far side painted over the near side and its surface glow (a sphere
    /// normal facing away from the camera) turned the whole frame white.
    @MainActor
    func testTheNearSideStaysWaterMidMorph() async throws {
        let harness = try makeHarness(size: 256)
        let presentation = ImmersiveMapSettings.default.presentation
        let latitudeExtension = log2(1.0 / cos(Self.latitude * .pi / 180.0))
        let midMorphZoom = presentation.automaticTransitionStartZoom
            + (presentation.automaticTransitionSpan + latitudeExtension) * 0.5
        let center = ImmersiveMapProjection.worldMercator(latitude: Self.latitude * .pi / 180.0,
                                                          longitude: Self.longitude * .pi / 180.0)
        let resolved = PresentationStateResolver.resolve(cameraState: ImmersiveMapCameraState(centerWorldMercator: center,
                                                                                              zoom: midMorphZoom,
                                                                                              bearing: 0,
                                                                                              pitch: 0),
                                                         settings: presentation)
        XCTAssertGreaterThan(resolved.globeRenderUniform.transition, 0, "The premise: the surface is unfurling")
        XCTAssertLessThan(resolved.globeRenderUniform.transition, 1, "and has not finished")

        harness.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: Self.latitude,
                                                              longitudeDegrees: Self.longitude,
                                                              zoom: midMorphZoom))
        let baseline = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(0))
        try await loadFixtureTiles(into: harness, maximumZoom: 8)
        let painted = try await harness.renderUntilSettled(changedFrom: baseline,
                                                            startingAt: OffscreenFrameHarness.frameTime(1))
        XCTAssertTrue(isWaterLike(painted.center),
                      "The centre must stay the water colour mid-morph, got \(painted.center)")
        let middle = painted.size / 2
        let radius = painted.size / 10
        var offColour = 0
        for y in (middle - radius) ... (middle + radius) {
            for x in (middle - radius) ... (middle + radius)
            where (x - middle) * (x - middle) + (y - middle) * (y - middle) <= radius * radius {
                if isWaterLike(painted.pixel(x: x, y: y)) == false {
                    offColour += 1
                }
            }
        }
        XCTAssertEqual(offColour, 0, "\(offColour) pixels around the centre are not water mid-morph")
    }

    /// Under an oblique view the near side is still front-facing: the sense
    /// of the winding declaration holds when the sphere is seen at an angle,
    /// not only from straight above.
    @MainActor
    func testTheNearSideIsIntactUnderAPitchedCamera() async throws {
        let harness = try makeHarness()
        harness.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: Self.latitude,
                                                              longitudeDegrees: Self.longitude,
                                                              zoom: 1.5,
                                                              bearing: 0,
                                                              pitch: 0.5))
        let baseline = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(0))
        try await loadFixtureTiles(into: harness, maximumZoom: 2)
        let painted = try await harness.renderUntilSettled(changedFrom: baseline,
                                                            startingAt: OffscreenFrameHarness.frameTime(1))
        XCTAssertTrue(isWaterLike(painted.center),
                      "The near side under an oblique view is front-facing, got \(painted.center)")
        XCTAssertGreaterThan(painted.count(where: isWaterLike), painted.size * painted.size / 8)
    }

    // MARK: - Helpers

    @MainActor
    private func makeHarness(size: Int = 160) throws -> OffscreenFrameHarness {
        // Below the street palette the style paints water with the global
        // landcover blue and only eases toward `layers.water` as the camera
        // zooms in (the street palette blend is zero at these zooms), so the
        // colour this test owns is the overview one.
        let configuration = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault
            .globalLandcover {
                $0.water = Self.fixtureWater
                // The overview biomes blend forest toward grass by zoom: both
                // cyan, so the far side is cyan at every zoom of the morph.
                $0.forest = Self.fixtureForest
                $0.grass = Self.fixtureForest
            }
        var settings = ImmersiveMapSettings.default
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

    /// Every tile of every zoom up to `maximumZoom`: water where the tile's
    /// centre lies within `waterWithinDegrees` of the camera, forest beyond.
    @MainActor
    private func loadWorldFixtureTiles(into harness: OffscreenFrameHarness,
                                       maximumZoom: Int,
                                       waterWithinDegrees: Double) async throws {
        let water = VectorTileFixture.fullCoverageTile(layerName: "water", properties: ["class": "ocean"])
        // The overview zooms draw the continuous `globallandcover` biomes and
        // hide the OSM `landcover` layer, so the far side is a biome forest.
        let forest = VectorTileFixture.fullCoverageTile(layerName: "globallandcover", properties: ["class": "forest"])
        let cameraLatitude = Self.latitude * .pi / 180
        let cameraLongitude = Self.longitude * .pi / 180
        for z in 0...maximumZoom {
            let count = 1 << z
            for x in 0..<count {
                for y in 0..<count {
                    let longitude = (Double(x) + 0.5) / Double(count) * 2 * .pi - .pi
                    let mercatorY = .pi * (1 - 2 * (Double(y) + 0.5) / Double(count))
                    let latitude = atan(sinh(mercatorY))
                    let angle = acos(min(1, sin(latitude) * sin(cameraLatitude)
                        + cos(latitude) * cos(cameraLatitude) * cos(longitude - cameraLongitude)))
                    let data = angle * 180 / .pi < waterWithinDegrees ? water : forest
                    let didMaterialize = await harness.tileRenderStore.parseTile(tile: Tile(x: x, y: y, z: z), data: data)
                    XCTAssertTrue(didMaterialize, "Fixture tile \(z)/\(x)/\(y) must parse")
                }
            }
        }
    }

    /// The far side's cyan through the globe shading and the horizon fog,
    /// which mixes it toward the warm off-white map colour by distance: cyan
    /// keeps red well under blue up to about 80 per cent fog, while the water
    /// (red-heavy), the map colour and the fog itself (red at or above blue)
    /// and the grey of space never do.
    private func isForestLike(_ pixel: RenderedFrame.Pixel) -> Bool {
        Int(pixel.red) < Int(pixel.blue) - 40 && Int(pixel.green) > Int(pixel.blue) - 30
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
