// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// Where the paint on a carriageway treats a point as a junction: it stops
/// short of one, leaving the crossing clear.
///
/// The question is what counts as one. A street arrives cut into pieces the
/// stitcher cannot always close, and a driveway meets it every few doors;
/// treating either as a junction breaks the line on a street that simply
/// continues.
final class RoadMarkingJunctionTests: XCTestCase {
    /// The junction of the fixtures, in render space (the parser flips y).
    /// Deliberately OFF the tile centre: the first fixtures sat at
    /// (2048, 2048), the fixed point of the y mirror, where a mirror bug
    /// lands back on itself and passes. Here a mirrored junction misses by
    /// over a thousand units.
    private static let junction = SIMD2<Float>(1500, 4096 - 2600)

    private func makeParser() -> TileMvtParser {
        let config = ImmersiveMapSettings.default
        let runtimeContext = ImmersiveMapProviderRuntimeContext(settings: config)
        return TileMvtParser(determineFeatureStyle: DetermineFeatureStyle(mapStyle: runtimeContext.mapStyle),
                             labelProviderProfile: runtimeContext.labelProviderProfile,
                             config: config,
                             glyphCoverage: .legacyAtlasForTests)
    }

    /// How close the paint on the avenue gets to the junction point, in tile
    /// units. Paint that runs through it comes within a dash of it; paint
    /// that stops short leaves half a carriageway.
    private func closestPaintToJunction(_ second: VectorTileFixture.Feature,
                                        streetOfAvenue: String? = nil) throws -> Float {
        var avenue: [String: String] = ["class": "primary", "lanes": "4", "name": "Avenue"]
        if let streetOfAvenue { avenue["street"] = streetOfAvenue }
        let data = VectorTileFixture.layerTile(layerName: "transportation", features: [
            .init(id: 1,
                  geometry: .line(points: [(200, 2600), (1500, 2600), (3900, 2600)]),
                  properties: avenue),
            second
        ])
        let parsed = try makeParser().parse(tile: Tile(x: 39615, y: 20486, z: 16), mvtData: data)
        let detail = parsed.drawingRoadPhases.automobileGround.detail
        var closest = Float.greatestFiniteMagnitude
        for vertex in detail.drawing.vertices {
            let point = SIMD2<Float>(Float(vertex.position.x), Float(vertex.position.y))
            closest = min(closest, simd_distance(point, Self.junction))
        }
        return closest
    }

    /// A four-lane primary is about 16 m across, which is a hundred tile
    /// units at z16 in Moscow: paint held back by half of that clears the
    /// junction by much more than a dash length.
    private let clearedGap: Float = 40

    func testPaintStopsShortOfAJunction() throws {
        let crossing = VectorTileFixture.Feature(
            id: 2,
            // OSM splits ways where they meet, so a real crossing shares the
            // node; the engine reads junctions off shared nodes, not off
            // geometric intersections.
            geometry: .line(points: [(1500, 400), (1500, 2600), (1500, 3700)]),
            properties: ["class": "primary", "lanes": "4", "name": "Cross Street"]
        )
        XCTAssertGreaterThan(try closestPaintToJunction(crossing), clearedGap,
                             "The divider leaves the crossing street clear")
    }

    func testASeamInOneStreetIsNotAJunction() throws {
        // The same street, cut where its lane count changes: the stitcher
        // leaves the two pieces apart, and both carry the shared point. The
        // geometry is the driveway's, so the only difference from a junction
        // is whose street the second piece is.
        let continuation = VectorTileFixture.Feature(
            id: 2,
            geometry: .line(points: [(1500, 2600), (1500, 3600)]),
            properties: ["class": "primary", "lanes": "6", "name": "Avenue"]
        )
        XCTAssertLessThan(try closestPaintToJunction(continuation), clearedGap,
                          "A street that continues carries its line through the seam")
    }

    func testTheSourcesStreetIdentityDecidesWhatIsASeam() throws {
        // The tiler assembles streets before cutting tiles and states which
        // street a piece belongs to. Two pieces of one street meeting is a
        // seam even where their attributes differ, and two pieces of
        // different streets meeting is a junction even where they agree.
        let sameStreet = VectorTileFixture.Feature(
            id: 2,
            geometry: .line(points: [(1500, 2600), (1500, 3600)]),
            properties: ["class": "primary", "lanes": "6", "name": "Avenue", "street": "77"]
        )
        XCTAssertLessThan(try closestPaintToJunction(sameStreet, streetOfAvenue: "77"), clearedGap,
                          "One street on the ground: the paint runs through")

        let otherStreet = VectorTileFixture.Feature(
            id: 2,
            geometry: .line(points: [(1500, 2600), (1500, 3600)]),
            properties: ["class": "primary", "lanes": "4", "name": "Avenue", "street": "88"]
        )
        XCTAssertGreaterThan(try closestPaintToJunction(otherStreet, streetOfAvenue: "77"), clearedGap,
                             "Two streets that share a name: the paint still stops")
    }

    /// Paint broken at a junction resumes in step on the far side.
    ///
    /// The dash pattern is cut from arc length, and every tessellated piece
    /// used to start counting at zero, so each block of a street began with a
    /// fresh full stroke wherever the line had been cut. Pieces now carry how
    /// far along the line they begin.
    func testTheDashPatternCarriesOnAcrossAJunction() {
        let line: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(100, 0), SIMD2(250, 0), SIMD2(400, 0)]
        let fragment = ClippedLineFragment(points: line, startClipped: false, endClipped: false)
        let counts: [TileMvtParser.RoadConnectionPointKey: Int] = [
            .init(point: SIMD2(100, 0)): 2,
            .init(point: SIMD2(250, 0)): 2
        ]
        let pieces = TileMvtParser.splitAtJunctionsWithOrigins(fragment: fragment,
                                                               automobilePointCounts: counts)
        XCTAssertEqual(pieces.count, 3)
        XCTAssertEqual(pieces[0].arcLengthOrigin, 0, "The first piece starts the count")
        XCTAssertEqual(pieces[1].arcLengthOrigin, 100, accuracy: 0.001,
                       "and the second carries on from where the first ended")
        XCTAssertEqual(pieces[2].arcLengthOrigin, 250, accuracy: 0.001)
    }

    func testADrivewayIsNotAJunction() throws {
        // A service road meeting an avenue is a way onto a plot, and the
        // markings on the avenue run past it as they do on the ground.
        let driveway = VectorTileFixture.Feature(
            id: 2,
            geometry: .line(points: [(1500, 2600), (1500, 3600)]),
            properties: ["class": "service", "lanes": "1", "name": "Yard"]
        )
        XCTAssertLessThan(try closestPaintToJunction(driveway), clearedGap,
                          "Paint does not break for a gateway")
    }
}
