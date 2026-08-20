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
    /// The junction the fixtures put in the middle of the tile, in render
    /// space (the parser flips y).
    private static let junction = SIMD2<Float>(2048, 4096 - 2048)

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
    private func closestPaintToJunction(_ second: VectorTileFixture.Feature) throws -> Float {
        let data = try VectorTileFixture.layerTile(layerName: "transportation", features: [
            .init(id: 1,
                  geometry: .line(points: [(200, 2048), (2048, 2048), (3900, 2048)]),
                  properties: ["class": "primary", "lanes": "4", "name": "Avenue"]),
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
            geometry: .line(points: [(2048, 400), (2048, 2048), (2048, 3700)]),
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
            geometry: .line(points: [(2048, 2048), (2048, 3000)]),
            properties: ["class": "primary", "lanes": "6", "name": "Avenue"]
        )
        XCTAssertLessThan(try closestPaintToJunction(continuation), clearedGap,
                          "A street that continues carries its line through the seam")
    }

    func testADrivewayIsNotAJunction() throws {
        // A service road meeting an avenue is a way onto a plot, and the
        // markings on the avenue run past it as they do on the ground.
        let driveway = VectorTileFixture.Feature(
            id: 2,
            geometry: .line(points: [(2048, 2048), (2048, 3000)]),
            properties: ["class": "service", "lanes": "1", "name": "Yard"]
        )
        XCTAssertLessThan(try closestPaintToJunction(driveway), clearedGap,
                          "Paint does not break for a gateway")
    }
}
