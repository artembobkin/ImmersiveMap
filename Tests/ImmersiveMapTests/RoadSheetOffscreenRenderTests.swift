// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// End to end: translucent roads that overlap draw as one sheet, every pixel
/// blended once. Two streets cross at the centre of the frame, and the
/// crossing must be the colour of a street on its own, not the darker patch
/// two composited layers leave. One case crosses two ground streets (one
/// group of the sheet), the other a ground street and a bridge (two road
/// structures in one sheet). Requires the compiled Metal library, so it
/// skips under `swift test` and runs in the xcodebuild workspace suite.
final class RoadSheetOffscreenRenderTests: XCTestCase {
    /// A road colour that appears nowhere else, at half opacity so a second
    /// composite is far outside the tolerance.
    private static let fixtureRoad = SIMD4<Float>(1, 0, 0, 0.5)
    private static let tile = Tile(x: 9908, y: 5140, z: 14)

    @MainActor
    func testTwoGroundStreetsCrossAsOneSheet() async throws {
        try await assertCrossingIsOneSheet(crossingProperties: ProtomapsRoadSpelling.properties(forClass: "primary"))
    }

    @MainActor
    func testABridgeOverAStreetCrossesAsOneSheet() async throws {
        try await assertCrossingIsOneSheet(crossingProperties: ProtomapsRoadSpelling.properties(forClass: "primary")
            .merging(["is_bridge": "true"]) { _, new in new })
    }

    /// The sheet writes its depth from the fragment stage, and under
    /// multisampling that depth and the sheet's stencil bit are per sample.
    @MainActor
    func testABridgeOverAStreetCrossesAsOneSheetUnderMultisampling() async throws {
        try await assertCrossingIsOneSheet(crossingProperties: ProtomapsRoadSpelling.properties(forClass: "primary")
            .merging(["is_bridge": "true"]) { _, new in new },
                                           multisampled: true)
    }

    @MainActor
    private func assertCrossingIsOneSheet(crossingProperties: [String: String],
                                          multisampled: Bool = false,
                                          file: StaticString = #filePath,
                                          line: UInt = #line) async throws {
        let theme = ProtomapsBasemapTheme.default.layers { $0.roads.primary = Self.fixtureRoad }
        var settings = FixtureTiles.tilelessSettings()
            .mapStyle(ProtomapsBasemapMapStyle(theme: theme))
            .msaa(isEnabled: multisampled)
        settings.scene.starfield.starCount = 0
        let harness = try OffscreenFrameHarness.makeOrSkip(settings: settings)

        let centerUv = (x: (Double(Self.tile.x) + 0.5) / Double(1 << Self.tile.z),
                        y: (Double(Self.tile.y) + 0.5) / Double(1 << Self.tile.z))
        let latitude = atan(sinh(Double.pi * (1.0 - 2.0 * centerUv.y))) * 180.0 / .pi
        let longitude = centerUv.x * 360.0 - 180.0
        harness.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: latitude,
                                                              longitudeDegrees: longitude,
                                                              zoom: 14.2))
        let baseline = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(0))

        // A street along the tile's middle row and one along its middle
        // column: they cross under the camera.
        let data = VectorTileFixture.layerTile(layerName: "roads", features: [
            .road(id: 1, points: [(0, 2048), (4096, 2048)]),
            .init(id: 2, geometry: .line(points: [(2048, 0), (2048, 4096)]), properties: crossingProperties)
        ])
        let loaded = await harness.tileRenderStore.parseTile(tile: Self.tile, data: data)
        XCTAssertTrue(loaded, "The fixture tile must parse", file: file, line: line)
        let painted = try await harness.renderUntilSettled(changedFrom: baseline,
                                                            startingAt: OffscreenFrameHarness.frameTime(1))

        let center = painted.size / 2
        let away = painted.size / 4
        let crossing = painted.pixel(x: center, y: center)
        let alongRow = painted.pixel(x: center + away, y: center)
        let alongColumn = painted.pixel(x: center, y: center + away)
        let ground = painted.pixel(x: center + away, y: center + away)

        XCTAssertGreaterThan(Int(ground.green) - Int(alongRow.green), 40,
                             "The street along the row must be painted", file: file, line: line)
        XCTAssertGreaterThan(Int(ground.green) - Int(alongColumn.green), 40,
                             "The street along the column must be painted", file: file, line: line)
        for (name, single) in [("row", alongRow), ("column", alongColumn)] {
            XCTAssertEqual(Int(crossing.green), Int(single.green), accuracy: 4,
                           "The crossing must be blended once, like the street along the \(name)",
                           file: file, line: line)
            XCTAssertEqual(Int(crossing.red), Int(single.red), accuracy: 4, file: file, line: line)
        }
    }
}
