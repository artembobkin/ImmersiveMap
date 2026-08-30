// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// End-to-end over the path the engine exists for: real MVT bytes go in, and
/// the colour the style assigns to them has to come out of a rendered frame.
///
/// The stretch covered here is MVT decode → `TileMvtParser` → triangulation →
/// `PreparedTileCPU` → `MetalTileFactory` → the tile cache → placement and
/// atlas → the ground shader → pixels. Every stage of that had unit tests and
/// none of it had a test that ran the whole thing, so a break anywhere in the
/// middle could only be found by looking at the screen.
///
/// The bytes are built in the test (see `VectorTileFixture`) rather than
/// downloaded: the pipeline runs offline and deterministically, and the
/// fixture's geometry is readable instead of being an opaque committed blob.
/// The network transport and the disk caches are the two stages deliberately
/// left out; both are covered by `ImmersiveMapNeedsTileTests` and
/// `PreparedTileDiskCodecTests`.
///
/// Requires the compiled Metal library, so it skips under `swift test` and runs
/// in the xcodebuild workspace suite.
final class TilePipelineOffscreenRenderTests: XCTestCase {
    /// A colour that appears nowhere else in the map: whatever else the frame
    /// paints, a pixel this colour came from the fixture tile.
    private static let fixtureWater = SIMD4<Float>(1, 0, 1, 1)

    /// Zoom 14 is past the flat transition (it saturates at zoom 7) and past
    /// the style's global-landcover overview (it ends at zoom 9), so the water
    /// layer takes its colour from `layers.water`, the one this test sets.
    private static let renderZoom = 14.0

    private static let camera = ImmersiveMapCameraPosition(latitudeDegrees: 55.75,
                                                           longitudeDegrees: 37.61,
                                                           zoom: renderZoom)

    @MainActor
    func testFixtureTileReachesTheRenderedFrame() async throws {
        let harness = try makeHarness()
        harness.setCameraPosition(Self.camera)

        let baseline = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(0))
        XCTAssertEqual(baseline.count(where: isFixtureWater), 0,
                       "Nothing may be this colour before the fixture tile is loaded")

        try await loadFixtureTiles(into: harness, layerName: "water")
        let painted = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(1))

        XCTAssertGreaterThan(painted.count(where: isFixtureWater),
                             painted.size * painted.size / 2,
                             "A tile covered edge to edge by water must fill most of the frame")
        XCTAssertGreaterThan(harness.engine.currentDiagnostics?.counterValue(.renderedTiles) ?? 0,
                             0,
                             "The frame must report the tiles it drew")
    }

    /// The road buckets are drawn with back-face culling on, so a ribbon
    /// wound the wrong way would vanish: avenues across the tile at every
    /// zoom of the pyramid must change the frame.
    @MainActor
    func testRoadRibbonsReachTheFrameWithBackFaceCullingOn() async throws {
        let harness = try makeHarness()
        harness.setCameraPosition(Self.camera)
        let baseline = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(0))

        // One avenue every 256 units, so whichever part of the tile the frame
        // shows, a ribbon crosses it.
        let avenues: [VectorTileFixture.Feature] = (0..<16).map { row in
            let y = Int32(128 + row * 256)
            let points: [(Int32, Int32)] = [(0, y), (4096, y)]
            return .init(id: UInt64(row + 1),
                         geometry: .line(points: points),
                         properties: ["class": "primary", "lanes": "4", "name": "Avenue \(row)"])
        }
        let data = VectorTileFixture.layerTile(layerName: "transportation", features: avenues)
        let tiles = WebMercatorTileScheme.neighbourhoodPyramid(latitude: Self.camera.latitudeDegrees,
                                                               longitude: Self.camera.longitudeDegrees,
                                                               maximumZoom: Int(Self.renderZoom))
        for tile in tiles {
            let didMaterialize = await harness.tileRenderStore.parseTile(tile: tile, data: data)
            XCTAssertTrue(didMaterialize, "Fixture tile \(tile.z)/\(tile.x)/\(tile.y) must parse")
        }
        let painted = try await harness.renderUntilSettled(changedFrom: baseline,
                                                            startingAt: OffscreenFrameHarness.frameTime(1))
        XCTAssertGreaterThan(painted.differingByteCount(from: baseline), painted.size * 4,
                             "A ribbon at least a pixel wide crosses the frame")
    }

    /// The colour is the style's answer about the layer, not a property of the
    /// bytes: the same geometry in a layer the style paints differently must
    /// come out differently. Without this, a tile that reached the frame as an
    /// untyped fallback fill would satisfy the test above.
    @MainActor
    func testTheStyleDecidesTheColourOfTheParsedGeometry() async throws {
        let harness = try makeHarness()
        harness.setCameraPosition(Self.camera)
        let baseline = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(0))

        // A landcover class the style paints (wood is green at this zoom): the
        // engine's map color is the style's land, so a tile whose only paint
        // is the synthetic land quad leaves the frame exactly as it was, by
        // design, and could not prove it arrived.
        try await loadFixtureTiles(into: harness, layerName: "landcover", className: "wood")
        let painted = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(1))

        // Both halves are needed. Without the first, a frame where the ground
        // shader drew nothing at all would satisfy the second and the test
        // would pass for the wrong reason.
        XCTAssertNotEqual(painted, baseline,
                          "The landcover tile must reach the frame and paint something")
        XCTAssertEqual(painted.count(where: isFixtureWater), 0,
                       "Only the water layer may take the water colour")
    }

    /// Geometry that fails to parse must not be materialized as an empty tile
    /// that then reads as ready forever: the store has to reject it.
    @MainActor
    func testCorruptTileBytesAreRejectedInsteadOfMaterialized() async throws {
        let harness = try makeHarness()
        harness.setCameraPosition(Self.camera)

        let tile = WebMercatorTileScheme.tile(latitude: Self.camera.latitudeDegrees,
                                              longitude: Self.camera.longitudeDegrees,
                                              z: Int(Self.renderZoom))
        let corrupt = Data([0xFF, 0xFE, 0xFD, 0xFC, 0x00, 0x01])
        let didMaterialize = await harness.tileRenderStore.parseTile(tile: tile, data: corrupt)

        XCTAssertFalse(didMaterialize, "Bytes that are not a vector tile must not become a tile")
        XCTAssertNil(harness.tileRenderStore.getMetalTile(tile: tile),
                     "A rejected tile must leave nothing in the cache")
    }

    // MARK: - Helpers

    /// The default style with one colour changed, so the assertion names a
    /// value this test owns instead of pinning whatever the palette happens to
    /// use for water today.
    ///
    /// The earth scene is off: its terminator shades the map by date, and a
    /// darkened magenta would no longer match the colour it was given.
    @MainActor
    private func makeHarness() throws -> OffscreenFrameHarness {
        let configuration = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault
            .layers { $0.water = Self.fixtureWater }
        let settings = ImmersiveMapSettings.default
            .earthScene(isEnabled: false)
            .mapStyle(ImmersiveMapTilesMapStyle(configuration: configuration))
        return try OffscreenFrameHarness.makeOrSkip(settings: settings)
    }

    /// Feeds the fixture straight into the tile store, which is where the
    /// network loader would deliver it.
    ///
    /// The store is fed the neighbourhood at every zoom rather than one tile:
    /// which tiles a frame demands is the coverage policy's decision (source
    /// zoom, viewport reach, fallback ancestors), and a test that predicted it
    /// would be asserting on the policy instead of on the pipeline.
    @MainActor
    private func loadFixtureTiles(into harness: OffscreenFrameHarness,
                                  layerName: String,
                                  className: String? = nil) async throws {
        let data = VectorTileFixture.fullCoverageTile(layerName: layerName,
                                                          properties: ["class": className ?? layerName])
        let tiles = WebMercatorTileScheme.neighbourhoodPyramid(latitude: Self.camera.latitudeDegrees,
                                                               longitude: Self.camera.longitudeDegrees,
                                                               maximumZoom: Int(Self.renderZoom))
        for tile in tiles {
            let didMaterialize = await harness.tileRenderStore.parseTile(tile: tile, data: data)
            XCTAssertTrue(didMaterialize,
                          "Fixture tile \(tile.z)/\(tile.x)/\(tile.y) must parse and reach the GPU")
        }
    }

    /// Exact equality is deliberate: the ground shader paints the style colour
    /// as given, and a near-miss would mean something (lighting, fog, a blend)
    /// touched a pixel that must arrive untouched.
    private func isFixtureWater(_ pixel: RenderedFrame.Pixel) -> Bool {
        pixel.red == 255 && pixel.green == 0 && pixel.blue == 255
    }
}
