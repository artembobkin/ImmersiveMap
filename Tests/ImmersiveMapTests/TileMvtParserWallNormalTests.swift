// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// Pins the wall-normal orientation contract of `buildExtrudedMesh`: every
/// wall normal must point out of the building material, regardless of the
/// input ring winding (`ensureWinding` normalizes it). The shadow shader
/// relies on this: an away-from-sun normal means geometric self-shadow, so an
/// inward wall normal makes a sunlit facade flip dark whenever the two-sided
/// camera test cannot rescue it (walls seen at grazing angles).
final class TileMvtParserWallNormalTests: XCTestCase {
    private func makeParser() -> TileMvtParser {
        let config = ImmersiveMapSettings.default
        return TileMvtParser(
            determineFeatureStyle: DetermineFeatureStyle(mapStyle: ImmersiveMapTilesDefaultMapStyle()),
            labelProviderProfile: ImmersiveMapProviderRuntimeContext(settings: config).labelProviderProfile,
            config: config,
            glyphCoverage: .legacyAtlasForTests
        )
    }

    private func makeMesh(exterior: [SIMD2<Float>],
                          interiors: [[SIMD2<Float>]] = []) -> TileMvtParser.ParsedExtrudedMesh? {
        let parser = makeParser()
        let roofVertices = exterior.map { SIMD2<Int16>(Int16($0.x), Int16($0.y)) }
        return parser.buildExtrudedMesh(clippedExterior: exterior,
                                        clippedInteriors: interiors,
                                        roof: TileMvtParser.ParsedPolygon(vertices: roofVertices,
                                                                          indices: [0, 1, 2, 0, 2, 3]),
                                        roofInfo: nil,
                                        baseHeight: 0,
                                        topHeight: 50,
                                        tileExtent: 4096)
    }

    /// Signed radial component of a wall vertex normal relative to `center`:
    /// positive when the normal points away from the center.
    private func radialComponents(of mesh: TileMvtParser.ParsedExtrudedMesh,
                                  center: SIMD2<Float>,
                                  where isIncluded: (SIMD3<Float>) -> Bool = { _ in true }) -> [Float] {
        mesh.vertices.compactMap { vertex in
            guard abs(vertex.normal.z) < 0.5, isIncluded(vertex.position) else { return nil }
            let toVertex = SIMD2<Float>(vertex.position.x, vertex.position.y) - center
            return simd_dot(SIMD2<Float>(vertex.normal.x, vertex.normal.y), simd_normalize(toVertex))
        }
    }

    func testExteriorWallNormalsPointOutwardForBothInputWindings() {
        let counterClockwise: [SIMD2<Float>] = [
            SIMD2(1000, 1000), SIMD2(1200, 1000), SIMD2(1200, 1200), SIMD2(1000, 1200)
        ]
        for ring in [counterClockwise, counterClockwise.reversed()] {
            guard let mesh = makeMesh(exterior: ring) else {
                XCTFail("Expected an extruded mesh")
                return
            }
            let radials = radialComponents(of: mesh, center: SIMD2(1100, 1100))
            XCTAssertEqual(radials.count, 16, "Four walls with four vertices each")
            for radial in radials {
                XCTAssertGreaterThan(radial, 0.1, "Exterior wall normal must point out of the building")
            }
        }
    }

    func testHoleWallNormalsPointIntoTheHole() {
        let exterior: [SIMD2<Float>] = [
            SIMD2(1000, 1000), SIMD2(1400, 1000), SIMD2(1400, 1400), SIMD2(1000, 1400)
        ]
        let hole: [SIMD2<Float>] = [
            SIMD2(1150, 1150), SIMD2(1250, 1150), SIMD2(1250, 1250), SIMD2(1150, 1250)
        ]
        guard let mesh = makeMesh(exterior: exterior, interiors: [hole]) else {
            XCTFail("Expected an extruded mesh")
            return
        }
        let holeCenter = SIMD2<Float>(1200, 1200)
        let isOnHoleRing: (SIMD3<Float>) -> Bool = { position in
            (1149...1251).contains(position.x) && (1149...1251).contains(position.y)
        }
        let holeRadials = radialComponents(of: mesh, center: holeCenter, where: isOnHoleRing)
        XCTAssertEqual(holeRadials.count, 16, "Four hole walls with four vertices each")
        for radial in holeRadials {
            XCTAssertLessThan(radial, -0.1, "Hole wall normal must point into the hole cavity")
        }
        let exteriorRadials = radialComponents(of: mesh, center: SIMD2(1200, 1200)) { !isOnHoleRing($0) }
        XCTAssertEqual(exteriorRadials.count, 16)
        for radial in exteriorRadials {
            XCTAssertGreaterThan(radial, 0.1, "Exterior wall normal must point out of the building")
        }
    }
}
