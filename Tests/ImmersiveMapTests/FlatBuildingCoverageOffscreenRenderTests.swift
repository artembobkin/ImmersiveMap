// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// End-to-end contract of the building coverage (`BuildingCoveragePlanner`):
/// only the tiles of the frame's target zoom draw buildings, each in its
/// own place. A z14 cell with a building over its whole extent stands in
/// on the ground for the z15 children that have not arrived, and extrudes
/// nothing there: the frame is the same with the extrusion on and off.
/// With the cell as the target it draws its building. The building's
/// footprint is a ground fill in the same colour, which is why the frames
/// are compared whole rather than by colour. Requires the compiled Metal
/// library, so it skips under `swift test` and runs in the xcodebuild
/// workspace suite.
final class FlatBuildingCoverageOffscreenRenderTests: XCTestCase {
    /// Colours that appear nowhere else in the map.
    private static let fixtureWater = SIMD4<Float>(1, 0, 1, 1)
    private static let fixtureSnow = SIMD4<Float>(0, 1, 1, 1)
    private static let fixtureBuilding = SIMD4<Float>(1, 1, 0, 1)

    /// The z14 cell 9908/5140 and its north-west z15 child. The camera
    /// looks at the cell's centre, the corner all four children share, from
    /// the south at a tilt, so the three missing children's quadrants are
    /// in view with the loaded one.
    private static let cell = Tile(x: 9908, y: 5140, z: 14)
    private static let child = Tile(x: 19816, y: 10280, z: 15)

    @MainActor
    func testACoarserTileStandingInDrawsNoBuilding() async throws {
        let standingIn = try await differingBytes(zoom: 15.2, buildingsMinimumZoom: 15)
        XCTAssertEqual(standingIn, 0,
                       "The cell standing in for the missing children extrudes nothing: the extrusion changes no pixel")

        let asTarget = try await differingBytes(zoom: 14.5, buildingsMinimumZoom: 14)
        XCTAssertGreaterThan(asTarget, 0, "The cell as the target draws its building")
    }

    /// The bytes that differ between the frame with the extrusion on and
    /// the one with it off, at `zoom` over the cell's centre.
    @MainActor
    private func differingBytes(zoom: Double, buildingsMinimumZoom: Double) async throws -> Int {
        var frames: [RenderedFrame] = []
        for buildingExtrusion in [true, false] {
            let harness = try makeHarness(buildingExtrusion: buildingExtrusion, buildingsMinimumZoom: buildingsMinimumZoom)
            let centerUv = (x: (Double(Self.cell.x) + 0.5) / Double(1 << Self.cell.z),
                            y: (Double(Self.cell.y) + 0.5) / Double(1 << Self.cell.z))
            let latitude = atan(sinh(Double.pi * (1.0 - 2.0 * centerUv.y))) * 180.0 / .pi
            let longitude = centerUv.x * 360.0 - 180.0
            harness.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: latitude,
                                                                  longitudeDegrees: longitude,
                                                                  zoom: zoom,
                                                                  bearing: 0,
                                                                  pitch: 1.0))
            let baseline = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(0))

            // The cell: water ground and one building over its whole extent.
            // The child: snow ground, no buildings.
            let waterData = VectorTileFixture.fullCoverageTile(layerName: "water",
                                                               properties: ["kind": "ocean"])
            let buildingData = VectorTileFixture.fullCoverageTile(layerName: "buildings",
                                                                  properties: ["kind": "building", "height": "40"])
            let snowData = VectorTileFixture.fullCoverageTile(layerName: "landuse",
                                                              properties: ["kind": "glacier"])
            let cellLoaded = await harness.tileRenderStore.parseTile(tile: Self.cell, data: waterData + buildingData)
            XCTAssertTrue(cellLoaded, "The cell fixture tile must parse")
            let childLoaded = await harness.tileRenderStore.parseTile(tile: Self.child, data: snowData)
            XCTAssertTrue(childLoaded, "The child fixture tile must parse")

            frames.append(try await harness.renderUntilSettled(changedFrom: baseline,
                                                                startingAt: OffscreenFrameHarness.frameTime(1)))
        }
        return frames[0].differingByteCount(from: frames[1])
    }

    // MARK: - Helpers

    @MainActor
    private func makeHarness(buildingExtrusion: Bool, buildingsMinimumZoom: Double) throws -> OffscreenFrameHarness {
        let configuration = ProtomapsBasemapTheme.default
            .layers { layers in
                layers.water = Self.fixtureWater
                layers.ice = Self.fixtureSnow
            }
            .features { features in
                features.buildingFillColor = Self.fixtureBuilding
                features.buildingExtrusion = buildingExtrusion
            }
        var settings = ImmersiveMapSettings.default
            .mapStyle(ProtomapsBasemapMapStyle(theme: configuration))
        settings.scene.extrusion.buildingsMinimumZoom = buildingsMinimumZoom
        settings.scene.extrusion.riseSeconds = 0
        settings.scene.starfield.starCount = 0
        // No cast shadows: they would tint the sampled snow according to the
        // sun's azimuth.
        settings.scene.shadows.isEnabled = false
        return try OffscreenFrameHarness.makeOrSkip(settings: settings)
    }
}
