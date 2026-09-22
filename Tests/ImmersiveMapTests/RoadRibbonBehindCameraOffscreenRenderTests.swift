// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// End to end: a road segment that begins behind the camera draws its
/// visible part on its own centreline. The deferred ribbons are extruded by
/// the vertex stage (Tile.metal), which floors the depth of a vertex behind
/// the near plane. The vertex is cut, but it still shapes the triangle: a
/// ribbon extruded wider at one row than at the other is a trapezoid, and
/// the distance field a trapezoid cut into two triangles interpolates bends
/// at the diagonal, so the visible part of the segment drew veering off the
/// centreline, by more the closer it came, and the whole road swung with the
/// camera's bearing (a straight bridge kinked at the tile seam under a
/// street tilt). The width lies on the ground, one ground width per style,
/// so a vertex behind the camera must extrude by the same width as every
/// other vertex of its ribbon.
///
/// The camera looks along a straight road under the full street tilt, a
/// little off the road's bearing (a road exactly along the view is immune,
/// its extrusion direction changes no depth). The road drawn from behind the
/// camera must sit where the same road drawn from in front of it does, row
/// by row. Requires the compiled Metal library, so it skips under
/// `swift test` and runs in the xcodebuild workspace suite.
final class RoadRibbonBehindCameraOffscreenRenderTests: XCTestCase {
    /// A road colour that appears nowhere else in the map.
    private static let fixtureRoad = SIMD4<Float>(1, 0, 0, 1)
    private static let tile = Tile(x: 19816, y: 10280, z: 15)
    private static let frameSize = 200
    /// The road runs along the tile's middle column, from the south edge
    /// (plus the buffer the clipper keeps) to the north edge.
    private static let roadColumn: Int32 = 2048
    /// The look-at point: on the road, near the tile's north edge, so that
    /// at a street zoom the road's south end lies behind the camera (the
    /// camera stands about half a tile back from the point it looks at).
    private static let lookAtRow: Int32 = 1000
    /// The row the reference road starts at: well in front of the camera,
    /// under the lower half of the frame.
    private static let referenceStartRow: Int32 = 2500
    /// The full street tilt, and a bearing a little east of the road.
    private static let pitch: Float = .pi * 5.0 / 12.0
    private static let bearing: Float = 0.3
    private static let zoom = 15.9

    @MainActor
    func testASegmentThatBeginsBehindTheCameraDrawsOnItsCentreline() async throws {
        let full = try await renderRoad(points: [(Self.roadColumn, 4160), (Self.roadColumn, -64)])
        let reference = try await renderRoad(points: [(Self.roadColumn, Self.referenceStartRow),
                                                      (Self.roadColumn, -64)])

        // The rows both roads cover: from just under the road's far end
        // (the tile's north edge, a little above the centre of the frame)
        // down to just above the reference road's cap.
        let centre = Self.frameSize / 2
        let rows = (centre - 12) ... (centre + 50)
        var comparedRows = 0
        var largestOffset = 0.0
        for row in rows {
            guard let referenceSpan = roadSpan(reference, row: row) else {
                continue
            }
            comparedRows += 1
            guard let fullSpan = roadSpan(full, row: row) else {
                XCTFail("Row \(row): the road drawn from behind the camera is missing where the reference road is at \(referenceSpan)")
                continue
            }
            let offset = abs(Double(fullSpan.min + fullSpan.max) - Double(referenceSpan.min + referenceSpan.max)) / 2
            largestOffset = max(largestOffset, offset)
            XCTAssertLessThanOrEqual(offset, 1.5,
                                     "Row \(row): the road drawn from behind the camera sits at \(fullSpan), the reference at \(referenceSpan)")
        }
        XCTAssertGreaterThan(comparedRows, 40, "The reference road must cover the compared rows")
        XCTAssertLessThanOrEqual(largestOffset, 1.5,
                                 "The road drawn from behind the camera must lie on the reference road's centreline")
    }

    // MARK: - Helpers

    /// Renders the fixture tile holding one primary road through `points`
    /// (tile units, y down) under the test's camera and returns the settled
    /// frame.
    @MainActor
    private func renderRoad(points: [(Int32, Int32)]) async throws -> RenderedFrame {
        let theme = ImmersiveMapTilesTheme.default.layers { $0.roads.primary = Self.fixtureRoad }
        var settings = FixtureTiles.tilelessSettings()
            .mapStyle(ImmersiveMapTilesMapStyle(theme: theme))
        settings.scene.starfield.starCount = 0
        let harness = try OffscreenFrameHarness.makeOrSkip(settings: settings, size: Self.frameSize)

        let scale = Double(1 << Self.tile.z)
        let lookAtUv = (x: (Double(Self.tile.x) + Double(Self.roadColumn) / 4096.0) / scale,
                        y: (Double(Self.tile.y) + Double(Self.lookAtRow) / 4096.0) / scale)
        let latitude = atan(sinh(Double.pi * (1.0 - 2.0 * lookAtUv.y))) * 180.0 / .pi
        let longitude = lookAtUv.x * 360.0 - 180.0
        harness.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: latitude,
                                                              longitudeDegrees: longitude,
                                                              zoom: Self.zoom,
                                                              bearing: Self.bearing,
                                                              pitch: Self.pitch))
        let baseline = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(0))

        let data = VectorTileFixture.layerTile(layerName: "transportation", features: [
            .init(id: 1, geometry: .line(points: points), properties: ["class": "primary"])
        ])
        let loaded = await harness.tileRenderStore.parseTile(tile: Self.tile, data: data)
        XCTAssertTrue(loaded, "The fixture tile must parse")
        return try await harness.renderUntilSettled(changedFrom: baseline,
                                                    startingAt: OffscreenFrameHarness.frameTime(1))
    }

    /// The columns the road covers on `row`: the leftmost and the rightmost
    /// pixel in the fixture colour, nil when the row has none.
    private func roadSpan(_ frame: RenderedFrame, row: Int) -> (min: Int, max: Int)? {
        var span: (min: Int, max: Int)?
        for x in 0 ..< frame.size where isFixtureRoad(frame.pixel(x: x, y: row)) {
            span = (span.map { min($0.min, x) } ?? x, x)
        }
        return span
    }

    private func isFixtureRoad(_ pixel: RenderedFrame.Pixel) -> Bool {
        Int(pixel.red) - Int(pixel.green) > 60 && Int(pixel.red) - Int(pixel.blue) > 60
    }
}
