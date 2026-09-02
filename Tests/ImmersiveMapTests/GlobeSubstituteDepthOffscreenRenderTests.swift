// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// End-to-end contract of the sphere's substitute handling: a coarse tile
/// standing in for missing slots draws at its full extent, and the
/// source-zoom depth band keeps it out of every slot a finer tile owns (the
/// sphere has no slot clip distances any more). The camera sits on the
/// corner shared by the four children of one z2 parent: one child is loaded
/// exactly (snow, painted cyan), the parent (water, painted magenta) stands
/// in for the other three. Requires the compiled Metal library, so it skips
/// under `swift test` and runs in the xcodebuild workspace suite.
final class GlobeSubstituteDepthOffscreenRenderTests: XCTestCase {
    /// Colours that appear nowhere else in the map.
    private static let fixtureWater = SIMD4<Float>(1, 0, 1, 1)
    private static let fixtureSnow = SIMD4<Float>(0, 1, 1, 1)

    /// The parent tile 2/1/2 and its north-west child 4/2/3. The camera
    /// looks at the parent's centre, which is the corner all four children
    /// share, so every quadrant of the frame belongs to a different child
    /// slot: north-west to the exact child, the rest to the substitute.
    private static let parent = Tile(x: 2, y: 1, z: 2)
    private static let exactChild = Tile(x: 4, y: 2, z: 3)
    /// Geographic centre of the parent: world uv (0.625, 0.375).
    private static let cornerLatitude = 40.9799
    private static let cornerLongitude = 45.0

    @MainActor
    func testExactChildRejectsTheSubstituteInItsSlot() async throws {
        let harness = try makeHarness()
        harness.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: Self.cornerLatitude,
                                                              longitudeDegrees: Self.cornerLongitude,
                                                              zoom: 3.2))
        let baseline = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(0))

        let waterData = VectorTileFixture.fullCoverageTile(layerName: "water",
                                                           properties: ["class": "ocean"])
        let snowData = VectorTileFixture.fullCoverageTile(layerName: "globallandcover",
                                                          properties: ["class": "snow"])
        let parentLoaded = await harness.tileRenderStore.parseTile(tile: Self.parent, data: waterData)
        XCTAssertTrue(parentLoaded, "The parent fixture tile must parse")
        let childLoaded = await harness.tileRenderStore.parseTile(tile: Self.exactChild, data: snowData)
        XCTAssertTrue(childLoaded, "The child fixture tile must parse")

        let painted = try await harness.renderUntilSettled(changedFrom: baseline,
                                                            startingAt: OffscreenFrameHarness.frameTime(1))
        let center = painted.size / 2
        let inset = painted.size / 5
        // The slot boundary through the frame centre is a great-circle arc,
        // not a straight pixel line: the sampled square keeps a margin from
        // it so a boundary pixel is never blamed on the depth test.
        let margin = 8

        // The exact child's quadrant (north-west: up and left of the shared
        // corner) is snow only: the substitute covers this area too, and
        // only the depth rejection keeps it out.
        var substituteLeaks = 0
        var childPixels = 0
        for y in (center - inset) ..< (center - margin) {
            for x in (center - inset) ..< (center - margin) {
                let pixel = painted.pixel(x: x, y: y)
                if isFixtureSnow(pixel) { childPixels += 1 }
                if isFixtureWater(pixel) { substituteLeaks += 1 }
            }
        }
        XCTAssertGreaterThan(childPixels, (inset - margin) * (inset - margin) / 2,
                             "The exact child must paint its quadrant")
        XCTAssertEqual(substituteLeaks, 0,
                       "The substitute must be depth-rejected everywhere the exact child painted")

        // The sibling quadrants have no exact tiles: the substitute paints
        // them, at full extent, from the same single draw.
        let siblingProbes = [(center + inset / 2, center + inset / 2),
                             (center - inset / 2, center + inset / 2),
                             (center + inset / 2, center - inset / 2)]
        for (x, y) in siblingProbes {
            XCTAssertTrue(isFixtureWater(painted.pixel(x: x, y: y)),
                          "The substitute must cover the missing sibling slot at \(x), \(y)")
        }
    }

    // MARK: - Helpers

    @MainActor
    private func makeHarness() throws -> OffscreenFrameHarness {
        let configuration = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault
            .globalLandcover { landcover in
                landcover.water = Self.fixtureWater
                landcover.snow = Self.fixtureSnow
            }
        var settings = ImmersiveMapSettings.default
            .mapStyle(ImmersiveMapTilesMapStyle(configuration: configuration))
        settings.scene.starfield.starCount = 0
        return try OffscreenFrameHarness.makeOrSkip(settings: settings)
    }

    private func isFixtureWater(_ pixel: RenderedFrame.Pixel) -> Bool {
        pixel.red > 200 && pixel.green < 60 && pixel.blue > 200
    }

    private func isFixtureSnow(_ pixel: RenderedFrame.Pixel) -> Bool {
        pixel.red < 60 && pixel.green > 200 && pixel.blue > 200
    }
}
