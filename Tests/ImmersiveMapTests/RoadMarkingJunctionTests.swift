// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// Where the paint on a carriageway treats a point as a junction: it breaks
/// there, and the last stretch before the break is drawn solid.
///
/// The question is what counts as one. A street arrives cut into pieces the
/// stitcher cannot always close, and a driveway meets it every few doors;
/// treating either as a junction lights a twelve-metre solid stretch on a
/// street that simply continues, which is what turned a uniform broken line
/// into dashes of wildly different lengths.
final class RoadMarkingJunctionTests: XCTestCase {
    private func makeParser() -> TileMvtParser {
        let config = ImmersiveMapSettings.default
        let runtimeContext = ImmersiveMapProviderRuntimeContext(settings: config)
        return TileMvtParser(determineFeatureStyle: DetermineFeatureStyle(mapStyle: runtimeContext.mapStyle),
                             labelProviderProfile: runtimeContext.labelProviderProfile,
                             config: config,
                             glyphCoverage: .legacyAtlasForTests)
    }

    /// Triangles of the solid approach: the only marking pass with a
    /// point-locked width and no dash.
    private func solidApproachTriangles(_ second: VectorTileFixture.Feature) throws -> Int {
        let data = try VectorTileFixture.layerTile(layerName: "transportation", features: [
            .init(id: 1,
                  geometry: .line(points: [(200, 2048), (2048, 2048)]),
                  properties: ["class": "primary", "lanes": "4", "name": "Avenue"]),
            second
        ])
        let parsed = try makeParser().parse(tile: Tile(x: 39615, y: 20486, z: 16), mvtData: data)
        let detail = parsed.drawingRoadPhases.automobileGround.detail
        let solid = detail.lineStyles.indices.filter {
            detail.lineStyles[$0].dashLengthPoints == 0 && detail.lineStyles[$0].widthPoints > 0
        }
        guard solid.isEmpty == false else { return 0 }
        var count = 0
        var index = 0
        while index + 2 < detail.drawing.indices.count {
            let vertex = detail.drawing.vertices[Int(detail.drawing.indices[index])]
            if solid.contains(Int(vertex.styleIndex)) { count += 1 }
            index += 3
        }
        return count
    }

    func testASeamInOneStreetIsNotAJunction() throws {
        // The same street, cut where its lane count changes: the stitcher
        // leaves the two pieces apart, and both carry the shared point.
        let continuation = VectorTileFixture.Feature(
            id: 2,
            geometry: .line(points: [(2048, 2048), (3900, 2048)]),
            properties: ["class": "primary", "lanes": "6", "name": "Avenue"]
        )
        XCTAssertEqual(try solidApproachTriangles(continuation), 0,
                       "A street that continues carries its broken line through the seam")
    }

    func testAnotherStreetIsAJunction() throws {
        let crossing = VectorTileFixture.Feature(
            id: 2,
            // OSM splits ways where they meet, so a real crossing shares the
            // node; the engine reads junctions off shared nodes, not off
            // geometric intersections.
            geometry: .line(points: [(2048, 400), (2048, 2048), (2048, 3700)]),
            properties: ["class": "primary", "lanes": "4", "name": "Cross Street"]
        )
        XCTAssertGreaterThan(try solidApproachTriangles(crossing), 0,
                             "Where two streets meet, the paint goes solid on the approach")
    }

    func testADrivewayIsNotAJunction() throws {
        // A service road meeting an avenue is a way onto a plot, and the
        // markings on the avenue run past it as they do on the ground.
        let driveway = VectorTileFixture.Feature(
            id: 2,
            geometry: .line(points: [(2048, 2048), (2048, 3000)]),
            properties: ["class": "service", "lanes": "1", "name": "Yard"]
        )
        XCTAssertEqual(try solidApproachTriangles(driveway), 0,
                       "Paint does not break for a gateway")
    }
}
