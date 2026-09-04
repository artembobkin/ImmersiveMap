// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// The road graph the tiles are built from trims every street at each node,
/// and where two pieces of one street simply continue into each other the
/// trims leave a slit between the two carriageway polygons that no shipped
/// polygon covers. `RoadSurfaceGapBridger` paves each slit with a quad
/// spanning the two facing trim edges, found by the street's own line, and
/// the quad joins the surface set so the street's fallback ribbon is clipped
/// out of the slit instead of poking through at its own width. A slit is
/// paved only between two pieces of the SAME street identity, which keeps
/// the median of a dual carriageway and every unrelated gap open.
final class RoadSurfaceGapBridgeTests: XCTestCase {
    private func makeParser() -> TileMvtParser {
        let config = ImmersiveMapSettings.default.streetscape(isEnabled: true)
        let runtimeContext = ImmersiveMapProviderRuntimeContext(settings: config)
        return TileMvtParser(determineFeatureStyle: DetermineFeatureStyle(mapStyle: runtimeContext.mapStyle),
                             labelProviderProfile: runtimeContext.labelProviderProfile,
                             config: config,
                             glyphCoverage: .legacyAtlasForTests)
    }

    private let tile = Tile(x: 39615, y: 20486, z: 16)

    private func parse(_ features: [VectorTileFixture.Feature]) throws -> TileMvtParser.ParsedTile {
        try makeParser().parse(tile: tile,
                               mvtData: VectorTileFixture.layerTile(layerName: "transportation",
                                                                    features: features))
    }

    private func street(_ points: [(Int32, Int32)], id: UInt64 = 2, street: String = "6410",
                        extra: [String: String] = [:]) -> VectorTileFixture.Feature {
        // Two lanes keep the fallback ribbon (about 95 units here) well
        // inside the 250-unit surface band, so a probe near the band's edge
        // sees the paving quad and never the ribbon.
        var properties = ["class": "primary", "lanes": "2",
                          "name": "Tverskaya Street", "street": street]
        for (key, value) in extra { properties[key] = value }
        return .init(id: id, geometry: .line(points: points), properties: properties)
    }

    private func surface(_ ring: [(Int32, Int32)], id: UInt64 = 1, street: String = "6410",
                         extra: [String: String] = [:]) -> VectorTileFixture.Feature {
        var properties = ["class": "primary", "subclass": "carriageway_area",
                          "origin": "graph", "street": street]
        for (key, value) in extra { properties[key] = value }
        return .init(id: id, geometry: .polygon(ring: ring), properties: properties)
    }

    /// Deliberately OFF the tile centre and y-asymmetric (see Tile/README.md):
    /// two pieces of one street with a 40-unit slit (about 3.4 m at this
    /// tile) between their facing trim edges.
    private let westPiece: [(Int32, Int32)] = [(600, 700), (1400, 700), (1400, 950), (600, 950)]
    private let eastPiece: [(Int32, Int32)] = [(1440, 700), (2200, 700), (2200, 950), (1440, 950)]
    private let slitCentreTileSpace = SIMD2<Float>(1420, 825)

    /// Whether any automobile-tier fill triangle covers the point (given in
    /// tile space, converted to the render space the vertices live in).
    private func fillCovers(_ parsed: TileMvtParser.ParsedTile, tileSpacePoint: SIMD2<Float>) -> Bool {
        let point = SIMD2<Float>(tileSpacePoint.x,
                                 TileCoordinateSpace.renderY(tileSpacePoint.y))
        let drawing = parsed.drawingRoadPhases.automobileGround.fill.drawing
        let vertices = drawing.vertices
        let indices = drawing.indices
        var index = 0
        while index + 2 < indices.count {
            let a = SIMD2<Float>(Float(vertices[Int(indices[index])].position.x),
                                 Float(vertices[Int(indices[index])].position.y))
            let b = SIMD2<Float>(Float(vertices[Int(indices[index + 1])].position.x),
                                 Float(vertices[Int(indices[index + 1])].position.y))
            let c = SIMD2<Float>(Float(vertices[Int(indices[index + 2])].position.x),
                                 Float(vertices[Int(indices[index + 2])].position.y))
            let d1 = crossZ(b - a, point - a)
            let d2 = crossZ(c - b, point - b)
            let d3 = crossZ(a - c, point - c)
            let hasNegative = d1 < 0 || d2 < 0 || d3 < 0
            let hasPositive = d1 > 0 || d2 > 0 || d3 > 0
            if !(hasNegative && hasPositive) {
                return true
            }
            index += 3
        }
        return false
    }

    private func crossZ(_ lhs: SIMD2<Float>, _ rhs: SIMD2<Float>) -> Float {
        lhs.x * rhs.y - lhs.y * rhs.x
    }

    func testASlitBetweenTwoPiecesOfOneStreetIsPaved() throws {
        let paved = try parse([surface(westPiece), surface(eastPiece, id: 3),
                               street([(700, 825), (2100, 825)])])
        XCTAssertTrue(fillCovers(paved, tileSpacePoint: slitCentreTileSpace),
                      "The slit between the two trim edges is filled")
        // The finder is the street's own line: two bare surfaces state no
        // continuity, and nothing is paved between them.
        let bare = try parse([surface(westPiece), surface(eastPiece, id: 3)])
        XCTAssertFalse(fillCovers(bare, tileSpacePoint: slitCentreTileSpace),
                       "Without the street's line the slit stays open")
    }

    func testTheFallbackRibbonIsClippedOutOfTheSlitItUsedToPokeThrough() throws {
        // The paving joins the surface set before the ribbons are clipped,
        // so the street's line contributes NOTHING of its own: the fill
        // grows by exactly the paving quad (two triangles), not by a ribbon
        // stub with caps.
        let paved = try parse([surface(westPiece), surface(eastPiece, id: 3),
                               street([(700, 825), (2100, 825)])])
        let bare = try parse([surface(westPiece), surface(eastPiece, id: 3)])
        XCTAssertEqual(paved.drawingRoadPhases.automobileGround.fill.drawing.indices.count,
                       bare.drawingRoadPhases.automobileGround.fill.drawing.indices.count + 6,
                       "The slit gains one quad and the ribbon stub is gone")
        XCTAssertEqual(paved.drawingRoadPhases.automobileGround.casing.drawing.indices.count,
                       bare.drawingRoadPhases.automobileGround.casing.drawing.indices.count,
                       "and no casing appears anywhere: the automobile tier is kerbless")
    }

    func testTwoHalfPiecesMeetingAtTheNodeStillPave() throws {
        // The way boundary sits at the node in the middle of the slit and
        // the tiler did not merge the two lines (their widths differ, which
        // is exactly when the stitcher keeps them apart too): each line
        // leaves its own surface and ends at the shared node, and the halves
        // pair up by that end.
        let paved = try parse([surface(westPiece), surface(eastPiece, id: 3),
                               street([(700, 825), (1420, 825)], id: 4, extra: ["width": "210"]),
                               street([(1420, 825), (2100, 825)], id: 5, extra: ["width": "120"])])
        XCTAssertTrue(fillCovers(paved, tileSpacePoint: slitCentreTileSpace),
                      "The slit is paved from the two half-pieces")
    }

    func testTheMedianOfADualCarriagewayIsNeverPaved() throws {
        // Two parallel one-way halves of one named street carry different
        // street ids, and a line of a third street crossing both threads the
        // median between them. Nothing may pave that median: it is the real
        // ground between two separate roadways.
        let northbound = surface([(600, 700), (2200, 700), (2200, 950), (600, 950)], street: "6410")
        let southbound = surface([(600, 980), (2200, 980), (2200, 1230), (600, 1230)],
                                 id: 3, street: "6411")
        let crossing = street([(1000, 500), (1000, 1400)], id: 4, street: "777")
        let parsed = try parse([northbound, southbound, crossing])
        // The probe sits in the median far from the crossing line, where
        // only a paving between the two side edges could put fill.
        XCTAssertFalse(fillCovers(parsed, tileSpacePoint: SIMD2<Float>(1800, 965)),
                       "The median between two streets stays open")
    }

    func testAWideGapIsNotPaved() throws {
        // 260 units is about 22 m here: far beyond a connection trim, a
        // genuine hole in the street that must stay a hole.
        let west = surface([(600, 700), (1300, 700), (1300, 950), (600, 950)])
        let east = surface([(1560, 700), (2200, 700), (2200, 950), (1560, 950)], id: 3)
        let parsed = try parse([west, east, street([(700, 825), (2100, 825)])])
        // The probe sits in the gap near the top of the surface band, off
        // the ribbon the street legitimately keeps drawing there.
        XCTAssertFalse(fillCovers(parsed, tileSpacePoint: SIMD2<Float>(1430, 715)),
                       "A gap wider than a trim is not a slit")
    }

    func testADeckPieceDoesNotPairWithAGroundPiece() throws {
        // The east piece is a bridge deck: a different structure, so the
        // ground line never reads the span to it as a slit of its own tier.
        let deck = surface(eastPiece, id: 3, extra: ["brunnel": "bridge", "layer": "1"])
        let parsed = try parse([surface(westPiece), deck,
                                street([(700, 825), (2100, 825)])])
        // Probed off the ribbon: only a paving quad could fill this corner.
        XCTAssertFalse(fillCovers(parsed, tileSpacePoint: SIMD2<Float>(1420, 715)),
                       "A slit is a joint within one structure, not a ramp between two")
    }

    func testAHandMappedAreaDoesNotPave() throws {
        // Hand-mapped junction areas (no origin=graph) are hidden and are
        // not trimmed pieces of anything: no paving may hang off them.
        let handMappedWest = VectorTileFixture.Feature(id: 1,
                                                       geometry: .polygon(ring: westPiece),
                                                       properties: ["class": "primary",
                                                                    "subclass": "junction_area",
                                                                    "street": "6410"])
        let parsed = try parse([handMappedWest, surface(eastPiece, id: 3),
                                street([(700, 825), (2100, 825)])])
        // Probed off the ribbon: only a paving quad could fill this corner.
        XCTAssertFalse(fillCovers(parsed, tileSpacePoint: SIMD2<Float>(1420, 715)),
                       "A hidden hand-mapped area cannot be one side of a paving")
    }
}
