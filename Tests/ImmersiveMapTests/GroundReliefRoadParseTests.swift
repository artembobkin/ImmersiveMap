// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The roads of a flattened tile on a relief: with the ground relief on,
/// a road's ribbon takes a row of vertices at every crossing of the
/// flattening's grid, so it follows the relief between its nodes as the
/// ground does. Off, a segment stays one quad. The switch is prepared-cache
/// identity.
final class GroundReliefRoadParseTests: XCTestCase {
    private static let tile = Tile(x: 9651, y: 12319, z: 15)
    private static let extent = Float(TileCoordinateSpace.tileExtentDouble)

    private func parse(relief: Bool, grid: Int = 16) throws -> ParsedTile {
        var settings = ImmersiveMapSettings.default
        settings.tiles.groundFlattening.fromTileZoom = 15
        settings.tiles.groundFlattening.grid = grid
        settings.tiles.groundRelief.isEnabled = relief
        // One primary road straight across the tile, a third of the way
        // down, with a bend near its end so the join and the last segment
        // are there too.
        let road = VectorTileFixture.Feature(id: 1,
                                             geometry: .line(points: [(0, 1400), (3500, 1400), (4096, 1900)]),
                                             properties: ProtomapsRoadSpelling.properties(forClass: "primary"))
        return try TileMvtParser.forTests(settings: settings)
            .parse(tile: Self.tile, mvtData: VectorTileFixture.layerTile(layerName: "roads", features: [road]))
    }

    /// The distinct x positions of the ribbon's rows on the straight
    /// stretch: the centreline points of the rim vertices (the ones with a
    /// direction) at the road's y, in render space.
    private func rowPositions(_ parsed: ParsedTile) -> Set<Int> {
        let roadY = Self.extent - 1400
        var positions = Set<Int>()
        for layer in parsed.drawingRoadPhases.drawOrderBuckets.flatMap(\.drawOrderLayers) {
            for vertex in layer.drawing.vertices where vertex.normal != .zero && abs(vertex.position.y - roadY) < 0.01 {
                positions.insert(Int(vertex.position.x.rounded()))
            }
        }
        return positions
    }

    func testARoadOnAReliefTakesARowAtEveryGridCrossing() throws {
        let rows = rowPositions(try parse(relief: true, grid: 16))
        let step = 256
        for crossing in stride(from: step, to: 3500, by: step) {
            XCTAssertTrue(rows.contains(crossing), "A row at the grid line x = \(crossing)")
        }
        XCTAssertFalse(rows.contains(3), "No row off the grid")
    }

    func testTheRowsFollowTheGrid() throws {
        let rows = rowPositions(try parse(relief: true, grid: 64))
        XCTAssertTrue(rows.contains(64))
        XCTAssertTrue(rows.contains(3456))
        XCTAssertFalse(rows.contains(256 + 32))
    }

    func testARoadWithoutAReliefKeepsItsSegmentsWhole() throws {
        let rows = rowPositions(try parse(relief: false))
        for crossing in stride(from: 256, to: 3500, by: 256) {
            XCTAssertFalse(rows.contains(crossing), "No row at x = \(crossing)")
        }
    }

    func testARowIsAddedAtEveryCrossingBetweenTwoRows() {
        let rows = ParseLine.subdividedRows([(SIMD2<Float>(10, 20), 0), (SIMD2<Float>(550, 300), 1)], step: 256)
        XCTAssertEqual(rows.count, 5, "Crossings at x = 256, x = 512 and y = 256")
        XCTAssertEqual(rows[1].position.x, 256, accuracy: 0.001)
        XCTAssertEqual(rows[2].position.y, 256, accuracy: 0.001)
        XCTAssertEqual(rows[3].position.x, 512, accuracy: 0.001)
        for index in 1..<rows.count {
            XCTAssertGreaterThan(rows[index].parameter, rows[index - 1].parameter, "The parameter grows along the strip")
        }
        XCTAssertEqual(rows[1].parameter, (256 - 10) / 540, accuracy: 0.001)
    }

    func testARowOnAGridLineIsNotDoubled() {
        let rows = ParseLine.subdividedRows([(SIMD2<Float>(256, 0), 0), (SIMD2<Float>(512, 0), 1)], step: 256)
        XCTAssertEqual(rows.count, 2, "The endpoints lie on grid lines, nothing lies between")
    }

    func testTheReliefIsPreparedCacheIdentity() {
        func namespace(relief: Bool) -> String {
            var settings = ImmersiveMapSettings.default
            settings.tiles.groundRelief.isEnabled = relief
            let options = TileParseOptions(settings: settings)
            return PreparedTileCacheIdentity(preparedFormatVersion: 1,
                                             styleRevision: 1,
                                             tileSourceRevision: 1,
                                             textRevision: 1,
                                             labelLanguage: settings.labels.language,
                                             labelFallbackPolicy: settings.labels.fallbackPolicy,
                                             capitalMaximumZoom: 1,
                                             cityMaximumZoom: 1,
                                             smallSettlementMaximumZoom: 1,
                                             landmarkMinimumZoom: 1,
                                             addTestBorders: false,
                                             labelsEnabled: true,
                                             groundFlatteningFromTileZoom: options.groundFlatteningFromTileZoom,
                                             groundFlatteningGrid: options.groundFlatteningGrid,
                                             groundReliefEnabled: options.groundReliefEnabled).namespaceComponent
        }
        XCTAssertNotEqual(namespace(relief: true), namespace(relief: false))
        XCTAssertNil(TileParseOptions(settings: .default).reliefSubdivisionStep(tileZoom: 15), "Off by default")
        var settings = ImmersiveMapSettings.default
        settings.tiles.groundRelief.isEnabled = true
        settings.tiles.groundFlattening.grid = 32
        XCTAssertEqual(TileParseOptions(settings: settings).reliefSubdivisionStep(tileZoom: 15), 128)
        XCTAssertEqual(TileParseOptions(settings: settings).reliefSubdivisionStep(tileZoom: 8), 128,
                       "With the relief on every tile from its zoom is flattened, and its roads follow the grid")
        XCTAssertEqual(TileParseOptions(settings: settings).reliefSubdivisionStep(tileZoom: 11), 16,
                       "A zoom with a grid of its own follows that grid")
        XCTAssertNil(TileParseOptions(settings: settings).reliefSubdivisionStep(tileZoom: 5),
                     "A tile coarser than the relief's zoom is not flattened and keeps its roads")
        settings.tiles.groundRelief.isEnabled = false
        XCTAssertNil(TileParseOptions(settings: settings).reliefSubdivisionStep(tileZoom: 15), "A tile off the relief keeps its roads")
    }
}
