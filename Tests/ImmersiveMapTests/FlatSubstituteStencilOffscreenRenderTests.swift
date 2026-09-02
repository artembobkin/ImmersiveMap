// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// End-to-end contract of the FLAT map's substitute handling, the mirror of
/// GlobeSubstituteDepthOffscreenRenderTests: a coarse tile standing in for
/// missing slots draws at its full extent, and the tile-priority stencil
/// keeps it out of every slot a finer tile owns (the flat tiles have no
/// slot clip distances any more). The camera sits on the corner shared by
/// the four children of one z13 parent at a flat zoom: one child is loaded
/// exactly (snow, painted cyan), the parent (water, painted magenta) stands
/// in for the other three. Requires the compiled Metal library, so it
/// skips under `swift test` and runs in the xcodebuild workspace suite.
final class FlatSubstituteStencilOffscreenRenderTests: XCTestCase {
    /// Colours that appear nowhere else in the map.
    private static let fixtureWater = SIMD4<Float>(1, 0, 1, 1)
    private static let fixtureSnow = SIMD4<Float>(0, 1, 1, 1)

    /// The parent tile 4954/2570/13 and its north-west child 9908/5140/14.
    /// The camera looks at the parent's centre, the corner all four
    /// children share; zoom 14.2 is well past the flat transition.
    private static let parent = Tile(x: 4954, y: 2570, z: 13)
    private static let exactChild = Tile(x: 9908, y: 5140, z: 14)
    /// The z3 ancestor that the horizon backdrop draws under everything:
    /// loaded on purpose, because the backdrop must lose to the exact child
    /// through the stencil (it once flooded the whole frame by winning the
    /// rank-depth test against the finer background).
    private static let backdropAncestor = Tile(x: 4, y: 2, z: 3)

    @MainActor
    func testExactChildRejectsTheSubstituteInItsSlot() async throws {
        let harness = try makeHarness()
        let centerUv = (x: (Double(Self.parent.x) + 0.5) / Double(1 << Self.parent.z),
                        y: (Double(Self.parent.y) + 0.5) / Double(1 << Self.parent.z))
        let latitude = atan(sinh(Double.pi * (1.0 - 2.0 * centerUv.y))) * 180.0 / .pi
        let longitude = centerUv.x * 360.0 - 180.0
        harness.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: latitude,
                                                              longitudeDegrees: longitude,
                                                              zoom: 14.2))
        let baseline = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(0))

        let waterData = VectorTileFixture.fullCoverageTile(layerName: "water",
                                                           properties: ["class": "ocean"])
        let snowData = VectorTileFixture.fullCoverageTile(layerName: "globallandcover",
                                                          properties: ["class": "snow"])
        let parentLoaded = await harness.tileRenderStore.parseTile(tile: Self.parent, data: waterData)
        XCTAssertTrue(parentLoaded, "The parent fixture tile must parse")
        let backdropLoaded = await harness.tileRenderStore.parseTile(tile: Self.backdropAncestor, data: waterData)
        XCTAssertTrue(backdropLoaded, "The backdrop fixture tile must parse")
        let childLoaded = await harness.tileRenderStore.parseTile(tile: Self.exactChild, data: snowData)
        XCTAssertTrue(childLoaded, "The child fixture tile must parse")

        let painted = try await harness.renderUntilSettled(changedFrom: baseline,
                                                            startingAt: OffscreenFrameHarness.frameTime(1))
        let center = painted.size / 2
        let inset = painted.size / 5
        let margin = 4

        // The exact child's quadrant (north-west: up and left of the shared
        // corner) is snow only: the substitute covers this area too, and
        // only the stencil rejection keeps it out.
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
                       "The substitute must be stencil-rejected everywhere the exact child painted")

        // The sibling quadrants have no exact tiles: the substitute paints
        // them, at full extent, from one draw.
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
        // At street zooms the palette handover is complete and the ground
        // colours come from the street layers, so both palettes get the
        // fixture colours.
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
        pixel.red > 200 && pixel.green < 60 && pixel.blue > 200
    }

    private func isFixtureSnow(_ pixel: RenderedFrame.Pixel) -> Bool {
        pixel.red < 60 && pixel.green > 200 && pixel.blue > 200
    }
}
