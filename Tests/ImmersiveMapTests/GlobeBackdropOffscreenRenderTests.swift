// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The luminous planet body: on a globe whose tiles have not arrived, the
/// silhouette shows glowing near-white instead of open space, and the
/// moment a tile paints its slot, the body vanishes under it (hidden
/// surface removal against the opaque tile background). Requires the
/// compiled Metal library, so it skips under `swift test` and runs in the
/// xcodebuild workspace suite.
final class GlobeBackdropOffscreenRenderTests: XCTestCase {
    private static let fixtureWater = SIMD4<Float>(1, 0, 1, 1)

    @MainActor
    func testUnloadedGlobeShowsTheGlowingBodyAndTilesCoverIt() async throws {
        let configuration = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault
            .globalLandcover { landcover in
                landcover.water = Self.fixtureWater
            }
        var settings = ImmersiveMapSettings.default
            .mapStyle(ImmersiveMapTilesMapStyle(configuration: configuration))
        settings.scene.starfield.starCount = 0
        let harness = try OffscreenFrameHarness.makeOrSkip(settings: settings)
        harness.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: 20,
                                                              longitudeDegrees: 30,
                                                              zoom: 1.5))

        // No tiles yet: the planet's silhouette is the glowing body.
        let empty = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(0))
        let center = empty.size / 2
        let bodyPixel = empty.pixel(x: center, y: center)
        XCTAssertGreaterThan(bodyPixel.red, 200, "The unloaded globe glows near-white")
        XCTAssertGreaterThan(bodyPixel.green, 200)
        XCTAssertGreaterThan(bodyPixel.blue, 200)

        // A corner pixel is space, not body: the glow must not leak past
        // the silhouette.
        let corner = empty.pixel(x: 2, y: 2)
        XCTAssertLessThan(corner.red, 60, "Space around the globe stays dark")

        // A z0 tile arrives: its opaque background covers the body.
        let waterData = VectorTileFixture.fullCoverageTile(layerName: "water",
                                                           properties: ["class": "ocean"])
        let loaded = await harness.tileRenderStore.parseTile(tile: Tile(x: 0, y: 0, z: 0), data: waterData)
        XCTAssertTrue(loaded, "The fixture tile must parse")
        let painted = try await harness.renderUntilSettled(changedFrom: empty,
                                                            startingAt: OffscreenFrameHarness.frameTime(1))
        let coveredPixel = painted.pixel(x: center, y: center)
        XCTAssertTrue(coveredPixel.red > 200 && coveredPixel.green < 60 && coveredPixel.blue > 200,
                      "A painted slot must show the tile, not the body")
    }
}
