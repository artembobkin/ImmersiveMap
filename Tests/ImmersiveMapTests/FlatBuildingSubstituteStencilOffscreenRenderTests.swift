// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// End-to-end contract of the buildings' substitute handling: the world-pass
/// buildings carry no slot clip distances any more, so a parent standing in
/// for missing slots draws its buildings once at full extent, and the
/// tile-priority stencil test against the ownership prepass keeps them out
/// of every slot a finer tile owns. The exact child here has NO buildings
/// at all, which is the case the old "test against other buildings' marks"
/// idea could never solve: the rejection must come from the child's tile
/// ownership, not from its (absent) building silhouettes. Requires the
/// compiled Metal library, so it skips under `swift test` and runs in the
/// xcodebuild workspace suite.
final class FlatBuildingSubstituteStencilOffscreenRenderTests: XCTestCase {
    /// Colours that appear nowhere else in the map.
    private static let fixtureWater = SIMD4<Float>(1, 0, 1, 1)
    private static let fixtureSnow = SIMD4<Float>(0, 1, 1, 1)
    private static let fixtureBuilding = SIMD4<Float>(1, 1, 0, 1)

    /// The parent tile 4954/2570/13 and its north-west child 9908/5140/14,
    /// as in FlatSubstituteStencilOffscreenRenderTests: the camera looks at
    /// the parent's centre, the corner all four children share, so the
    /// north-west quadrant of the frame belongs to the exact child.
    private static let parent = Tile(x: 4954, y: 2570, z: 13)
    private static let exactChild = Tile(x: 9908, y: 5140, z: 14)

    @MainActor
    func testExactChildRejectsTheSubstitutesBuildings() async throws {
        let harness = try makeHarness()
        let centerUv = (x: (Double(Self.parent.x) + 0.5) / Double(1 << Self.parent.z),
                        y: (Double(Self.parent.y) + 0.5) / Double(1 << Self.parent.z))
        let latitude = atan(sinh(Double.pi * (1.0 - 2.0 * centerUv.y))) * 180.0 / .pi
        let longitude = centerUv.x * 360.0 - 180.0
        harness.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: latitude,
                                                              longitudeDegrees: longitude,
                                                              zoom: 14.2))
        let baseline = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(0))

        // The parent: water ground plus two buildings, one entirely inside
        // the exact child's quadrant (its "courtyard" from the child's point
        // of view: the child has nothing there) and one in the missing
        // north-east sibling's quadrant. MVT layers are top-level repeated
        // protobuf fields, so concatenating two one-layer tiles yields one
        // two-layer tile.
        let waterData = VectorTileFixture.fullCoverageTile(layerName: "water",
                                                           properties: ["class": "ocean"])
        let buildingsData = VectorTileFixture.layerTile(
            layerName: "building",
            features: [
                .init(id: 1,
                      geometry: .polygon(ring: [(1024, 1024), (2028, 1024), (2028, 2028), (1024, 2028)]),
                      properties: ["render_height": "40"]),
                .init(id: 2,
                      geometry: .polygon(ring: [(2068, 1024), (3072, 1024), (3072, 2028), (2068, 2028)]),
                      properties: ["render_height": "40"])
            ])
        let snowData = VectorTileFixture.fullCoverageTile(layerName: "globallandcover",
                                                          properties: ["class": "snow"])
        let parentLoaded = await harness.tileRenderStore.parseTile(tile: Self.parent,
                                                                   data: waterData + buildingsData)
        XCTAssertTrue(parentLoaded, "The parent fixture tile must parse")
        let childLoaded = await harness.tileRenderStore.parseTile(tile: Self.exactChild, data: snowData)
        XCTAssertTrue(childLoaded, "The child fixture tile must parse")

        let painted = try await harness.renderUntilSettled(changedFrom: baseline,
                                                            startingAt: OffscreenFrameHarness.frameTime(1))
        let center = painted.size / 2
        let inset = painted.size / 5
        let margin = 4

        // The exact child's quadrant (north-west of the shared corner) is
        // snow only: the parent's first building covers this area too, and
        // only the ownership stencil keeps it out; the child has no
        // buildings of its own to mark anything.
        var buildingLeaks = 0
        var childPixels = 0
        for y in (center - inset) ..< (center - margin) {
            for x in (center - inset) ..< (center - margin) {
                let pixel = painted.pixel(x: x, y: y)
                if isFixtureSnow(pixel) { childPixels += 1 }
                if isFixtureBuilding(pixel) { buildingLeaks += 1 }
            }
        }
        XCTAssertGreaterThan(childPixels, (inset - margin) * (inset - margin) / 2,
                             "The exact child must paint its quadrant")
        XCTAssertEqual(buildingLeaks, 0,
                       "The substitute's building must be stencil-rejected in the exact child's slot")

        // The missing north-east sibling: the substitute paints its ground
        // and its second building there in full.
        let probeX = center + inset / 2
        let probeY = center - inset / 2
        XCTAssertTrue(isFixtureBuilding(painted.pixel(x: probeX, y: probeY)),
                      "The substitute's building must cover the missing sibling slot")
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
            .features { features in
                features.buildingFillColor = Self.fixtureBuilding
            }
        var settings = ImmersiveMapSettings.default
            .mapStyle(ImmersiveMapTilesMapStyle(configuration: configuration))
        settings.scene.starfield.starCount = 0
        // No cast shadows: the sibling building's shadow would otherwise
        // tint the sampled snow according to the sun's azimuth.
        settings.scene.shadows.isEnabled = false
        return try OffscreenFrameHarness.makeOrSkip(settings: settings)
    }

    private func isFixtureWater(_ pixel: RenderedFrame.Pixel) -> Bool {
        pixel.red > 200 && pixel.green < 60 && pixel.blue > 200
    }

    private func isFixtureSnow(_ pixel: RenderedFrame.Pixel) -> Bool {
        pixel.red < 60 && pixel.green > 200 && pixel.blue > 200
    }

    private func isFixtureBuilding(_ pixel: RenderedFrame.Pixel) -> Bool {
        pixel.red > 200 && pixel.green > 200 && pixel.blue < 60
    }
}
