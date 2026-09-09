// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// End-to-end contract of the building coverage (`BuildingCoveragePlanner`):
/// buildings come from a partition of the ground over the loaded tiles. A
/// loaded z15 child draws its own buildings in its quadrant of the z14
/// cell, the cell draws its buildings clipped to the quadrants whose child
/// has not arrived, and with all four children loaded the cell draws
/// nothing. The parent here has a building over its whole extent and the
/// children have none, so the handover is visible as the building vanishing
/// quadrant by quadrant. Requires the compiled Metal library, so it skips
/// under `swift test` and runs in the xcodebuild workspace suite.
final class FlatBuildingCoverageOffscreenRenderTests: XCTestCase {
    /// Colours that appear nowhere else in the map.
    private static let fixtureWater = SIMD4<Float>(1, 0, 1, 1)
    private static let fixtureSnow = SIMD4<Float>(0, 1, 1, 1)
    private static let fixtureBuilding = SIMD4<Float>(1, 1, 0, 1)

    /// The z14 cell 9908/5140 and its four z15 children; the camera looks at
    /// the cell's centre, the corner all four children share.
    private static let cell = Tile(x: 9908, y: 5140, z: 14)
    private static let children = [Tile(x: 19816, y: 10280, z: 15), Tile(x: 19817, y: 10280, z: 15),
                                   Tile(x: 19816, y: 10281, z: 15), Tile(x: 19817, y: 10281, z: 15)]

    @MainActor
    func testTheCellDrawsItsBuildingUntilItsChildrenAreComplete() async throws {
        let harness = try makeHarness()
        let centerUv = (x: (Double(Self.cell.x) + 0.5) / Double(1 << Self.cell.z),
                        y: (Double(Self.cell.y) + 0.5) / Double(1 << Self.cell.z))
        let latitude = atan(sinh(Double.pi * (1.0 - 2.0 * centerUv.y))) * 180.0 / .pi
        let longitude = centerUv.x * 360.0 - 180.0
        harness.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: latitude,
                                                              longitudeDegrees: longitude,
                                                              zoom: 15.2))
        let baseline = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(0))

        // The cell: water ground and one building over its whole extent.
        // The children: snow ground, no buildings.
        let waterData = VectorTileFixture.fullCoverageTile(layerName: "water",
                                                           properties: ["class": "ocean"])
        let buildingData = VectorTileFixture.fullCoverageTile(layerName: "building",
                                                              properties: ["render_height": "40"])
        let snowData = VectorTileFixture.fullCoverageTile(layerName: "globallandcover",
                                                          properties: ["class": "snow"])
        let cellLoaded = await harness.tileRenderStore.parseTile(tile: Self.cell, data: waterData + buildingData)
        XCTAssertTrue(cellLoaded, "The cell fixture tile must parse")
        let firstChildLoaded = await harness.tileRenderStore.parseTile(tile: Self.children[0], data: snowData)
        XCTAssertTrue(firstChildLoaded, "The child fixture tile must parse")

        let partial = try await harness.renderUntilSettled(changedFrom: baseline,
                                                            startingAt: OffscreenFrameHarness.frameTime(1))
        let center = partial.size / 2
        let inset = partial.size / 5
        let margin = 4
        // One child loaded: the child draws its quadrant (snow, no
        // buildings) and the cell's building is clipped to the other three,
        // the missing sibling's included; the cut runs along the quadrant's
        // edge, inside the margin.
        let childQuadrant = Self.count(in: partial, x: (center - inset) ..< (center - margin), y: (center - inset) ..< (center - margin))
        XCTAssertEqual(childQuadrant.building, 0,
                       "The loaded child's quadrant shows the child's buildings, none, not the cell's")
        XCTAssertGreaterThan(childQuadrant.snow, (inset - margin) * (inset - margin) / 2, "The child's snow shows")
        let siblingQuadrant = Self.count(in: partial, x: (center + margin) ..< (center + inset), y: (center - inset) ..< (center - margin))
        XCTAssertGreaterThan(siblingQuadrant.building, (inset - margin) * (inset - margin) / 2,
                             "The cell's building fills the missing sibling's quadrant")
        XCTAssertEqual(siblingQuadrant.snow, 0)

        for child in Self.children.dropFirst() {
            let loaded = await harness.tileRenderStore.parseTile(tile: child, data: snowData)
            XCTAssertTrue(loaded, "The child fixture tile must parse")
        }
        let complete = try await harness.renderUntilSettled(changedFrom: partial,
                                                             startingAt: OffscreenFrameHarness.frameTime(20))
        let whole = Self.count(in: complete, x: (center - inset) ..< (center + inset), y: (center - inset) ..< (center + inset))
        XCTAssertEqual(whole.building, 0, "All four children loaded: the cell hands over, and the children have no buildings")
        XCTAssertGreaterThan(whole.snow, (2 * inset) * (2 * inset) / 2, "The children's snow shows")
    }

    // MARK: - Helpers

    private static func count(in frame: RenderedFrame, x: Range<Int>, y: Range<Int>) -> (building: Int, snow: Int) {
        var building = 0
        var snow = 0
        for row in y {
            for column in x {
                let pixel = frame.pixel(x: column, y: row)
                if isFixtureBuilding(pixel) { building += 1 }
                if isFixtureSnow(pixel) { snow += 1 }
            }
        }
        return (building, snow)
    }

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
            .buildingExtrusion(isEnabled: true)
        settings.scene.starfield.starCount = 0
        // No cast shadows: they would tint the sampled snow according to the
        // sun's azimuth.
        settings.scene.shadows.isEnabled = false
        return try OffscreenFrameHarness.makeOrSkip(settings: settings)
    }

    private static func isFixtureSnow(_ pixel: RenderedFrame.Pixel) -> Bool {
        pixel.red < 60 && pixel.green > 200 && pixel.blue > 200
    }

    private static func isFixtureBuilding(_ pixel: RenderedFrame.Pixel) -> Bool {
        pixel.red > 200 && pixel.green > 200 && pixel.blue < 60
    }
}
