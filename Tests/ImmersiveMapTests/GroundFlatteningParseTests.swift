// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The flattened ground (`GroundFlattening`): from the configured tile
/// zoom on, a tile's ground fills come out as one layer whose triangles do
/// not overlap, every one inside a cell of the grid, the ground's area
/// shared out among the styles as the paint order would have shown it. A
/// coarser tile keeps its layers. The setting is prepared-cache identity.
final class GroundFlatteningParseTests: XCTestCase {
    private static let extent: Int32 = 4096

    /// A park over the whole tile and a lake square over its middle, the
    /// water the later style: two fills that overlap in the layered tile,
    /// over the tile's own land, and must not in the flattened one.
    private static func parkAndLakeTile() -> Data {
        let e = extent
        let park: [(Int32, Int32)] = [(0, 0), (e, 0), (e, e), (0, e)]
        let lake: [(Int32, Int32)] = [(1024, 1024), (3072, 1024), (3072, 3072), (1024, 3072)]
        return VectorTileFixture.layersTile([
            (layerName: "landuse",
             features: [VectorTileFixture.Feature(id: 1,
                                                  geometry: .polygon(ring: park),
                                                  properties: ["kind": "park"])]),
            (layerName: "water",
             features: [VectorTileFixture.Feature(id: 2,
                                                  geometry: .polygon(ring: lake),
                                                  properties: ["kind": "lake"])])
        ])
    }

    private func makeParser(fromTileZoom: Int?, grid: Int = 16) -> TileMvtParser {
        var config = ImmersiveMapSettings.default
        config.tiles.groundFlattening.fromTileZoom = fromTileZoom
        config.tiles.groundFlattening.grid = grid
        return TileMvtParser.forTests(settings: config, mapStyle: ProtomapsBasemapDefaultMapStyle())
    }

    /// The doubled signed area of every fill triangle, by style, in render
    /// space (y up): positive is counter-clockwise, the tile's winding.
    private func fillAreasByStyle(_ parsed: ParsedTile) -> (byStyle: [UInt8: Double], negative: Int, crossingCells: Int) {
        let vertices = parsed.drawingPolygon.vertices
        let indices = parsed.drawingPolygon.indices
        var byStyle: [UInt8: Double] = [:]
        var negative = 0
        var crossingCells = 0
        let cell = Double(Self.extent) / 16
        var i = 0
        while i + 2 < (parsed.drawingPolygon.fillsIndexCount ?? indices.count) {
            let a = vertices[Int(indices[i])], b = vertices[Int(indices[i + 1])], c = vertices[Int(indices[i + 2])]
            let ax = Double(a.position.x), ay = Double(a.position.y)
            let bx = Double(b.position.x), by = Double(b.position.y)
            let cx = Double(c.position.x), cy = Double(c.position.y)
            let doubled = (bx - ax) * (cy - ay) - (cx - ax) * (by - ay)
            if doubled < 0 { negative += 1 }
            byStyle[a.styleIndex, default: 0] += doubled / 2
            // A triangle inside a cell: its bounds lie within one cell's
            // bounds (an edge on a cell border counts for either side).
            let minX = min(ax, bx, cx), maxX = max(ax, bx, cx)
            let minY = min(ay, by, cy), maxY = max(ay, by, cy)
            if (minX / cell).rounded(.down) != ((maxX - 0.5) / cell).rounded(.down) && maxX - minX > 1
                || (minY / cell).rounded(.down) != ((maxY - 0.5) / cell).rounded(.down) && maxY - minY > 1 {
                crossingCells += 1
            }
            i += 3
        }
        return (byStyle, negative, crossingCells)
    }

    func testAFlattenedTileSharesTheGroundAmongItsFillsWithoutOverlap() throws {
        let parsed = try makeParser(fromTileZoom: 15).parse(tile: Tile(x: 9651, y: 12319, z: 15),
                                                           mvtData: Self.parkAndLakeTile())
        XCTAssertTrue(parsed.groundIsFlattened)
        let areas = fillAreasByStyle(parsed)
        let tileArea = Double(Self.extent) * Double(Self.extent)
        let lakeArea = 2048.0 * 2048.0
        let total = areas.byStyle.values.reduce(0, +)
        XCTAssertEqual(total, tileArea, accuracy: tileArea * 0.001,
                       "The fills cover the tile exactly once: no overlap, no gap")
        // The lake is the later style: it owns its square, the park the
        // rest, and the land under both is gone with its area.
        let lake = areas.byStyle.max { $0.key < $1.key }!
        XCTAssertEqual(lake.value, lakeArea, accuracy: lakeArea * 0.001)
        XCTAssertEqual(areas.byStyle.count, 2, "The land fill, covered everywhere, has no triangle left")
        XCTAssertEqual(areas.negative, 0, "Every triangle is counter-clockwise in render space")
        XCTAssertEqual(areas.crossingCells, 0, "No triangle crosses a cell of the grid")
    }

    /// A slanted edge crossing the grid: the sweep cuts it into slivers far
    /// thinner than a tile unit, which rounding the vertices used to flip
    /// or collapse into cracks. The vertices are the flattener's floats, so
    /// the mesh stays watertight: every interior edge is shared by two
    /// triangles in opposite directions, and no triangle is degenerate.
    func testAFlattenedTileIsWatertightAcrossASlantedEdge() throws {
        let e = Self.extent
        let park: [(Int32, Int32)] = [(0, 0), (e, 0), (e, e), (0, e)]
        let lake: [(Int32, Int32)] = [(100, 300), (3900, 1100), (3500, 3700), (700, 2900)]
        let data = VectorTileFixture.layersTile([
            (layerName: "landuse",
             features: [VectorTileFixture.Feature(id: 1, geometry: .polygon(ring: park), properties: ["kind": "park"])]),
            (layerName: "water",
             features: [VectorTileFixture.Feature(id: 2, geometry: .polygon(ring: lake), properties: ["kind": "lake"])])
        ])
        let parsed = try makeParser(fromTileZoom: 15).parse(tile: Tile(x: 9651, y: 12319, z: 15), mvtData: data)
        let vertices = parsed.drawingPolygon.vertices
        let indices = parsed.drawingPolygon.indices
        let fills = parsed.drawingPolygon.fillsIndexCount ?? indices.count
        var directedEdges: [SIMD4<Float>: Int] = [:]
        var degenerate = 0
        var i = 0
        while i + 2 < fills {
            let a = vertices[Int(indices[i])].position, b = vertices[Int(indices[i + 1])].position, c = vertices[Int(indices[i + 2])].position
            if ParsedPolygon.doubledArea(a, b, c) <= 0 { degenerate += 1 }
            for (s, t) in [(a, b), (b, c), (c, a)] {
                directedEdges[SIMD4<Float>(s.x, s.y, t.x, t.y), default: 0] += 1
            }
            i += 3
        }
        var open = 0
        for (edge, count) in directedEdges {
            let reverse = SIMD4<Float>(edge.z, edge.w, edge.x, edge.y)
            guard directedEdges[reverse] == nil else { continue }
            let onBorder = (edge.x == edge.z && (edge.x == 0 || edge.x == Float(e)))
                || (edge.y == edge.w && (edge.y == 0 || edge.y == Float(e)))
            if onBorder == false { open += count }
        }
        XCTAssertGreaterThan(fills / 3, 600, "The slanted lake cuts the grid into many triangles")
        XCTAssertEqual(degenerate, 0, "No triangle collapsed or flipped")
        XCTAssertEqual(open, 0, "Every interior edge is shared: no crack")
    }

    func testACoarserTileKeepsItsLayers() throws {
        let parsed = try makeParser(fromTileZoom: 15).parse(tile: Tile(x: 4825, y: 6159, z: 14),
                                                           mvtData: Self.parkAndLakeTile())
        XCTAssertFalse(parsed.groundIsFlattened)
        let areas = fillAreasByStyle(parsed)
        let tileArea = Double(Self.extent) * Double(Self.extent)
        let total = areas.byStyle.values.reduce(0, +)
        XCTAssertEqual(total, 2 * tileArea + 2048.0 * 2048.0, accuracy: tileArea * 0.001,
                       "The layered tile stacks the park over the land and the lake over both")
    }

    func testFlatteningOffKeepsEveryTileLayered() throws {
        let parsed = try makeParser(fromTileZoom: nil).parse(tile: Tile(x: 9651, y: 12319, z: 15),
                                                            mvtData: Self.parkAndLakeTile())
        XCTAssertFalse(parsed.groundIsFlattened)
    }

    func testTheFlattenedRunsAreMarked() throws {
        let parsed = try makeParser(fromTileZoom: 15).parse(tile: Tile(x: 9651, y: 12319, z: 15),
                                                           mvtData: Self.parkAndLakeTile())
        let ground = PreparedTileCPU.GeometryLayer(vertices: parsed.drawingPolygon.vertices,
                                                   indices: parsed.drawingPolygon.indices,
                                                   styles: parsed.styles,
                                                   styleZoomFades: parsed.styleZoomFades,
                                                   lineStyles: parsed.lineStyles,
                                                   fillsIndexCount: parsed.drawingPolygon.fillsIndexCount,
                                                   isFlattened: parsed.groundIsFlattened)
        let runs = GroundStyleRunScanner.scan(ground: ground)
        XCTAssertFalse(runs.isEmpty)
        for run in runs where run.isFillsClass {
            XCTAssertTrue(run.isFlattened, "A fill run of a flattened ground says so")
        }
    }

    func testTheSettingIsPreparedCacheIdentity() {
        func namespace(fromTileZoom: Int?, grid: Int) -> String {
            var identity = PreparedTileCacheIdentity(preparedFormatVersion: 140,
                                                     styleRevision: 1,
                                                     tileSourceRevision: 2,
                                                     textRevision: 3,
                                                     labelLanguage: .english,
                                                     labelFallbackPolicy: .international,
                                                     capitalMaximumZoom: 10,
                                                     cityMaximumZoom: 12,
                                                     smallSettlementMaximumZoom: 14,
                                                     landmarkMinimumZoom: 15,
                                                     addTestBorders: false,
                                                     labelsEnabled: true)
            identity.groundFlatteningFromTileZoom = fromTileZoom
            identity.groundFlatteningGrid = grid
            return identity.namespaceComponent
        }
        XCTAssertNotEqual(namespace(fromTileZoom: 15, grid: 16), namespace(fromTileZoom: nil, grid: 16))
        XCTAssertNotEqual(namespace(fromTileZoom: 15, grid: 16), namespace(fromTileZoom: 14, grid: 16))
        XCTAssertNotEqual(namespace(fromTileZoom: 15, grid: 16), namespace(fromTileZoom: 15, grid: 32))
    }

    func testTheModifiersLeaveTheOtherValueAsConfigured() {
        let settings = ImmersiveMapSettings.default
            .groundFlattening(fromTileZoom: 14, grid: 8)
            .groundFlattening(grid: 32)
        XCTAssertEqual(settings.tiles.groundFlattening.fromTileZoom, 14)
        XCTAssertEqual(settings.tiles.groundFlattening.grid, 32)
        let off = settings.groundFlattening(isEnabled: false)
        XCTAssertNil(off.tiles.groundFlattening.fromTileZoom)
        XCTAssertEqual(off.groundFlattening(isEnabled: true).tiles.groundFlattening.fromTileZoom, 15,
                       "Back on without a zoom, it starts from the default")
    }
}
