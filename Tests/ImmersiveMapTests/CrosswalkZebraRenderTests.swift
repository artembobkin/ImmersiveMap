// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// A marked pedestrian crossing draws as stripes on the carriageway.
///
/// The tiles ship the crossing as a line across the road, which is where it
/// is, which way it faces and how long it is; the style turns that into a
/// zebra in the automobile tier's detail role, above every carriageway.
@MainActor
final class CrosswalkZebraRenderTests: XCTestCase {
    /// The same tile is fed at every level, so the camera is aimed at the
    /// crossing's own point of the fixture tile (off the tile centre, see
    /// below): the crossing is then in the middle of the frame instead of
    /// somewhere off its edge.
    ///
    /// Written out one step at a time, with every type spelled: as a single
    /// arithmetic expression of untyped literals inside a multi-statement
    /// closure it type-checked here and timed the solver out on the CI
    /// compiler (Swift 6.1.2), which failed the whole test bundle.
    private static let camera: ImmersiveMapCameraPosition = makeCamera()

    private static func makeCamera() -> ImmersiveMapCameraPosition {
        let scale: Double = Double(1 << 16)
        let longitude: Double = (39616.5 / scale) * 360.0 - 180.0
        // The crossing sits at v = 1200/4096 of the fixture tile, OFF the
        // tile's y mirror line on purpose (a camera staring at v = 0.5 would
        // frame a mirrored figure just as well); the camera aims at it.
        let row: Double = 20487.0 + 1200.0 / 4096.0
        let normalizedY: Double = row / scale
        let mercatorY: Double = Double.pi * (1.0 - 2.0 * normalizedY)
        let latitude: Double = atan(sinh(mercatorY)) * 180.0 / Double.pi
        return ImmersiveMapCameraPosition(latitudeDegrees: latitude,
                                          longitudeDegrees: longitude,
                                          zoom: 18,
                                          pitch: 0)
    }

    /// The tile the camera sits on, which the fixture fills with the scene.
    func testTheCameraSitsOnTheFixtureTile() {
        let tile = WebMercatorTileScheme.tile(latitude: Self.camera.latitudeDegrees,
                                              longitude: Self.camera.longitudeDegrees,
                                              z: 16)
        XCTAssertEqual(tile.x, 39616)
        XCTAssertEqual(tile.y, 20487)
    }

    /// A four-lane avenue across the tile with one marked crossing over it.
    private static func tileData(crossing: String?) throws -> Data {
        var features: [VectorTileFixture.Feature] = [
            .init(id: 1,
                  geometry: .line(points: [(0, 1200), (4096, 1200)]),
                  properties: ["class": "primary", "lanes": "4", "name": "Avenue"])
        ]
        if let crossing {
            features.append(
                .init(id: 2,
                      geometry: .line(points: [(2048, 1052), (2048, 1352)]),
                      properties: ["class": "path", "subclass": "footway", "crossing": crossing])
            )
        }
        return VectorTileFixture.layerTile(layerName: "transportation", features: features)
    }

    func testAMarkedCrossingIsStripedOnTheCarriageway() throws {
        let parsed = try parse(crossing: "marked")
        let stripes = zebraTriangleCount(parsed)
        XCTAssertGreaterThan(stripes, 4, "A marked crossing paints a row of stripes")
    }

    func testAnUnmarkedCrossingIsNotStriped() throws {
        XCTAssertEqual(zebraTriangleCount(try parse(crossing: "unmarked")), 0,
                       "A crossing with no paint on the ground gets none on the map")
        XCTAssertEqual(zebraTriangleCount(try parse(crossing: "unknown")), 0,
                       "and neither does one nobody described")
        XCTAssertEqual(zebraTriangleCount(try parse(crossing: nil)), 0,
                       "A plain footway is not a crossing")
    }

    func testASignalledCrossingIsStriped() throws {
        XCTAssertGreaterThan(zebraTriangleCount(try parse(crossing: "traffic_signals")), 4,
                             "A signalled crossing is painted almost everywhere it exists")
    }

    /// The stripes have to reach the frame, not only the tile: they are
    /// polygons in a bucket whose other passes are lines, and the render path
    /// treats the two differently.
    func testTheStripesReachTheFrame() async throws {
        // The same scene twice, with the crossing marked and unmarked: the
        // feature is in the tile either way, so every pixel that differs
        // between the two frames is stripe paint.
        let marked = try await renderFrame(crossing: "marked")
        let unmarked = try await renderFrame(crossing: "unmarked")
        XCTAssertEqual(marked.size, unmarked.size)

        var painted = 0
        var minX = Int.max, maxX = -1
        for y in 0..<marked.size {
            for x in 0..<marked.size where marked.pixel(x: x, y: y) != unmarked.pixel(x: x, y: y) {
                painted += 1
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }
        XCTAssertGreaterThan(painted, 100, "The stripes have to reach the frame, not only the tile")
        // The crossing sits under the camera, so the paint belongs around
        // the centre of the frame, not spread across it (a mirrored or
        // misplaced figure would fail here).
        XCTAssertGreaterThan(minX, marked.size / 5, "The paint starts near the crossing")
        XCTAssertLessThan(maxX, marked.size * 4 / 5, "and ends near it")
    }

    /// A crossing can also arrive as a measured line (`marking=crossing_marked`
    /// from the road graph) instead of a tagged footway.
    func testAShippedCrossingLineIsStriped() throws {
        let parsed = try parse(features: [
            .init(id: 1,
                  geometry: .line(points: [(0, 1200), (4096, 1200)]),
                  properties: ["class": "primary", "lanes": "4", "name": "Avenue"]),
            .init(id: 2,
                  geometry: .line(points: [(2048, 1052), (2048, 1352)]),
                  properties: ["marking": "crossing_marked"]),
        ])
        XCTAssertGreaterThan(zebraTriangleCount(parsed), 4,
                             "A measured crossing line paints its stripes")
    }

    /// A tile that ships measured crossing lines may still carry the same
    /// crossings as tagged footways: the measured line wins, the tag is the
    /// same crossing seen twice.
    func testAMeasuredCrossingSilencesTheTaggedOne() throws {
        let shippedOnly = try parse(features: [
            .init(id: 2,
                  geometry: .line(points: [(2048, 1052), (2048, 1352)]),
                  properties: ["marking": "crossing_marked"]),
        ])
        let both = try parse(features: [
            .init(id: 2,
                  geometry: .line(points: [(2048, 1052), (2048, 1352)]),
                  properties: ["marking": "crossing_marked"]),
            .init(id: 3,
                  geometry: .line(points: [(2048, 1052), (2048, 1352)]),
                  properties: ["class": "path", "subclass": "footway", "crossing": "marked"]),
        ])
        XCTAssertEqual(zebraTriangleCount(both), zebraTriangleCount(shippedOnly),
                       "One crossing, one set of stripes")
    }

    // MARK: - Helpers

    private func parse(features: [VectorTileFixture.Feature]) throws -> TileMvtParser.ParsedTile {
        let config = ImmersiveMapSettings.default
        let runtimeContext = ImmersiveMapProviderRuntimeContext(settings: config)
        let parser = TileMvtParser(determineFeatureStyle: DetermineFeatureStyle(mapStyle: runtimeContext.mapStyle),
                                   labelProviderProfile: runtimeContext.labelProviderProfile,
                                   config: config,
                                   glyphCoverage: .legacyAtlasForTests)
        return try parser.parse(tile: Tile(x: 39615, y: 20486, z: 16),
                                mvtData: VectorTileFixture.layerTile(layerName: "transportation",
                                                                     features: features))
    }

    private func parse(crossing: String?) throws -> TileMvtParser.ParsedTile {
        let config = ImmersiveMapSettings.default
        let runtimeContext = ImmersiveMapProviderRuntimeContext(settings: config)
        let parser = TileMvtParser(determineFeatureStyle: DetermineFeatureStyle(mapStyle: runtimeContext.mapStyle),
                                   labelProviderProfile: runtimeContext.labelProviderProfile,
                                   config: config,
                                   glyphCoverage: .legacyAtlasForTests)
        return try parser.parse(tile: Tile(x: 39615, y: 20486, z: 16),
                                mvtData: Self.tileData(crossing: crossing))
    }

    /// Triangles in the detail role whose style is the crossing's: it is the
    /// only pass there with no point-locked width, since a stripe is an area
    /// on the ground rather than a stroke.
    private func zebraTriangleCount(_ parsed: TileMvtParser.ParsedTile) -> Int {
        let detail = parsed.drawingRoadPhases.automobileGround.detail
        let zebraStyles = detail.lineStyles.indices.filter { detail.lineStyles[$0].widthPoints == 0 }
        guard zebraStyles.isEmpty == false else { return 0 }
        var count = 0
        var index = 0
        while index + 2 < detail.drawing.indices.count {
            let vertex = detail.drawing.vertices[Int(detail.drawing.indices[index])]
            if zebraStyles.contains(Int(vertex.styleIndex)) { count += 1 }
            index += 3
        }
        return count
    }

    @MainActor
    private func renderFrame(crossing: String?) async throws -> RenderedFrame {
        let harness = try OffscreenFrameHarness.makeOrSkip(
            settings: ImmersiveMapSettings.default,
            size: 300
        )
        harness.setCameraPosition(Self.camera)
        let data = try Self.tileData(crossing: crossing)
        let tiles = WebMercatorTileScheme.neighbourhoodPyramid(latitude: Self.camera.latitudeDegrees,
                                                               longitude: Self.camera.longitudeDegrees,
                                                               maximumZoom: 16)
        for tile in tiles {
            _ = await harness.tileRenderStore.parseTile(tile: tile, data: data)
        }
        return try await harness.renderUntilSettled(startingAt: harness.lastFrameTime + 1.0)
    }
}
