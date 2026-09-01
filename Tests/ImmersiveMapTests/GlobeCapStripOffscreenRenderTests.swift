// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The polar caps continue the tiles: on a planet whose tiles are one
/// colour, the pole is that colour, not the palette's. Requires the compiled
/// Metal library, so it skips under `swift test` and runs in the xcodebuild
/// workspace suite.
final class GlobeCapStripOffscreenRenderTests: XCTestCase {
    /// A colour that appears nowhere else in the map.
    private static let fixtureWater = SIMD4<Float>(1, 0, 1, 1)

    /// Looking at the north pole at zoom 2.5 (past the tone deepening, no
    /// earth scene): the rim of the cap reads the strip baked from the
    /// magenta tiles, and the pole its windowed mean, so the whole cap is
    /// magenta once the tiles are in. Before they are, the cap paints the
    /// palette, which is not magenta.
    @MainActor
    func testCapContinuesTheTilesColourOverThePole() async throws {
        let harness = try makeHarness()
        // The camera centre cannot leave Mercator, so it sits on the last
        // tile row, a few pixels short of the cap; the disc checked below
        // reaches over the pole and down the far side.
        harness.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: 85.0,
                                                              longitudeDegrees: 0,
                                                              zoom: 2.5))
        let baseline = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(0))
        XCTAssertEqual(baseline.count(where: isFixtureWater), 0,
                       "Nothing may be this colour before the fixture tiles are loaded")

        try await loadFixtureTiles(into: harness, maximumZoom: 3)
        let painted = try await harness.renderUntilSettled(changedFrom: baseline,
                                                            startingAt: OffscreenFrameHarness.frameTime(1))
        // The disc around the pole: the cap and the last tile rows. With
        // the placeholder grid gone nothing under-paints the seam, so the
        // gaps between the tile chords and the cap's inner edge show space:
        // a bounded sliver of the ring is allowed to be space-coloured, but
        // the palette's pole white and the placeholder blue may not show.
        let center = painted.size / 2
        let radius = painted.size / 10
        var offColour = 0
        var checked = 0
        for y in (center - radius) ... (center + radius) {
            for x in (center - radius) ... (center + radius) where (x - center) * (x - center) + (y - center) * (y - center) <= radius * radius {
                checked += 1
                let pixel = painted.pixel(x: x, y: y)
                if pixel.red < 240 || pixel.green > 15 || pixel.blue < 240 {
                    offColour += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 100)
        XCTAssertLessThan(offColour, checked / 6,
                          "\(offColour) of \(checked) pixels around the pole are not the tiles' colour")
    }

    // MARK: - Helpers

    @MainActor
    private func makeHarness() throws -> OffscreenFrameHarness {
        // Below the street palette the style paints water with the global
        // landcover blue (see GlobeVectorSurfaceOffscreenRenderTests).
        let configuration = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault
            .globalLandcover { $0.water = Self.fixtureWater }
        var settings = ImmersiveMapSettings.default
            .mapStyle(ImmersiveMapTilesMapStyle(configuration: configuration))
        // The stars twinkle with scene time; a settle loop needs a still sky.
        settings.scene.starfield.starCount = 0
        return try OffscreenFrameHarness.makeOrSkip(settings: settings)
    }

    @MainActor
    private func loadFixtureTiles(into harness: OffscreenFrameHarness, maximumZoom: Int) async throws {
        let data = VectorTileFixture.fullCoverageTile(layerName: "water", properties: ["class": "ocean"])
        // Every tile of the pole rows down to `maximumZoom`, plus the
        // neighbourhood under the camera.
        var tiles = Set(WebMercatorTileScheme.neighbourhoodPyramid(latitude: 85.0,
                                                                   longitude: 0,
                                                                   maximumZoom: maximumZoom))
        for z in 0 ... maximumZoom {
            for x in 0 ..< (1 << z) {
                tiles.insert(Tile(x: x, y: 0, z: z))
            }
        }
        for tile in tiles.sorted(by: { ($0.z, $0.x) < ($1.z, $1.x) }) {
            let didMaterialize = await harness.tileRenderStore.parseTile(tile: tile, data: data)
            XCTAssertTrue(didMaterialize, "Fixture tile \(tile.z)/\(tile.x)/\(tile.y) must parse")
        }
    }

    private func isFixtureWater(_ pixel: RenderedFrame.Pixel) -> Bool {
        pixel.red == 255 && pixel.green == 0 && pixel.blue == 255
    }
}
