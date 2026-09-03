// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// End-to-end contract of the fill-outline antialiasing on the flat map: a
/// fill's edge comes out of the frame with a fringe of intermediate colour,
/// which the triangle rasterizer alone never produces (one sample per
/// pixel, no FXAA by default: every fill pixel is either the fill or what
/// lies under it). A magenta lozenge of water over cyan snow, with edges at
/// a shallow angle so the one-pixel outline meets the pixel grid at every
/// offset along each edge. Requires the compiled Metal library, so it skips
/// under `swift test` and runs in the xcodebuild workspace suite.
final class FlatFillOutlineOffscreenRenderTests: XCTestCase {
    private static let fixtureWater = SIMD4<Float>(1, 0, 1, 1)
    private static let fixtureSnow = SIMD4<Float>(0, 1, 1, 1)
    private static let renderZoom = 14.2
    private static let camera = ImmersiveMapCameraPosition(latitudeDegrees: 55.75,
                                                           longitudeDegrees: 37.61,
                                                           zoom: renderZoom)

    @MainActor
    func testFillEdgesCarryAnAntialiasedFringe() async throws {
        let harness = try makeHarness()
        harness.setCameraPosition(Self.camera)
        let baseline = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(0))
        XCTAssertEqual(baseline.count(where: isBlend), 0, "Nothing blends the two fixture colours before the tiles")

        // The lozenge is centred on the tile the camera looks at, three
        // quarters of a tile wide and a quarter tall: edges of slope 1:3,
        // so the distance from the outline to the pixel centres cycles
        // through its whole range along every edge.
        let lozenge: [(Int32, Int32)] = [(512, 2048), (2048, 1536), (3584, 2048), (2048, 2560)]
        let snow = VectorTileFixture.Feature(id: 1,
                                             geometry: .polygon(ring: [(0, 0), (4096, 0), (4096, 4096), (0, 4096)]),
                                             properties: ["class": "snow"])
        let water = VectorTileFixture.Feature(id: 2,
                                              geometry: .polygon(ring: lozenge),
                                              properties: ["class": "lake"])
        let data = VectorTileFixture.layersTile([("globallandcover", [snow]), ("water", [water])])
        let center = WebMercatorTileScheme.tile(latitude: Self.camera.latitudeDegrees,
                                                longitude: Self.camera.longitudeDegrees,
                                                z: Int(Self.renderZoom))
        let centerUv = (x: (Double(center.x) + 0.5) / Double(1 << center.z),
                        y: (Double(center.y) + 0.5) / Double(1 << center.z))
        let latitude = atan(sinh(Double.pi * (1.0 - 2.0 * centerUv.y))) * 180.0 / .pi
        let longitude = centerUv.x * 360.0 - 180.0
        harness.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: latitude,
                                                              longitudeDegrees: longitude,
                                                              zoom: Self.renderZoom))
        let tiles = WebMercatorTileScheme.neighbourhoodPyramid(latitude: latitude,
                                                               longitude: longitude,
                                                               maximumZoom: Int(Self.renderZoom))
        for tile in tiles {
            let didMaterialize = await harness.tileRenderStore.parseTile(tile: tile, data: data)
            XCTAssertTrue(didMaterialize, "Fixture tile \(tile.z)/\(tile.x)/\(tile.y) must parse")
        }
        let painted = try await harness.renderUntilSettled(changedFrom: baseline,
                                                            startingAt: OffscreenFrameHarness.frameTime(1))

        let waterPixels = painted.count(where: isFixtureWater)
        let blendPixels = painted.count(where: isBlend)
        XCTAssertTrue(isFixtureWater(painted.center), "The lozenge's interior is pure water")
        XCTAssertTrue(isFixtureSnow(painted.pixel(x: 4, y: 4)), "The far corner is pure snow")
        XCTAssertGreaterThan(waterPixels, 800, "The lozenge reached the frame (\(waterPixels) water pixels)")
        // Some 200 pixels of edge; with the outline at least a third of the
        // pixels along an edge of this slope land at a distance where the
        // fringe is neither colour, and the fill alone produces none.
        XCTAssertGreaterThan(blendPixels, 40,
                             "The fill's edges must carry the outline's intermediate fringe (\(blendPixels) blended pixels over \(waterPixels) of water)")
    }

    // MARK: - Helpers

    @MainActor
    private func makeHarness() throws -> OffscreenFrameHarness {
        let configuration = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault
            .globalLandcover { landcover in
                landcover.water = Self.fixtureWater
                landcover.snow = Self.fixtureSnow
            }
            .layers { layers in
                layers.water = Self.fixtureWater
                layers.ice = Self.fixtureSnow
            }
        var settings = ImmersiveMapSettings.default
            .mapStyle(ImmersiveMapTilesMapStyle(configuration: configuration))
        settings.scene.starfield.starCount = 0
        return try OffscreenFrameHarness.makeOrSkip(settings: settings)
    }

    private func isFixtureWater(_ pixel: RenderedFrame.Pixel) -> Bool {
        pixel.red > 230 && pixel.green < 25 && pixel.blue > 230
    }

    private func isFixtureSnow(_ pixel: RenderedFrame.Pixel) -> Bool {
        pixel.red < 25 && pixel.green > 230 && pixel.blue > 230
    }

    /// Magenta over cyan blends along the red and green channels only: a
    /// pixel with either well inside the range is the outline's fringe.
    private func isBlend(_ pixel: RenderedFrame.Pixel) -> Bool {
        pixel.blue > 230 && pixel.red > 60 && pixel.red < 200 && pixel.green > 60 && pixel.green < 200
    }
}
