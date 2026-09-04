// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import XCTest
import simd

/// Exercises `buildExtrudedMesh` with roof shapes end to end: the shaped roof
/// must share the flat lid's triangle winding (one of them being back-culled
/// while the other draws would make roofs vanish per shape), walls must rise to
/// meet gable ends, and unsupported footprints must fall back to a flat lid.
final class TileMvtParserRoofMeshTests: XCTestCase {
    private let topHeight: Float = 30
    private let roofHeight: Float = 10

    private let rectangle: [SIMD2<Float>] = [
        SIMD2(1000, 1000), SIMD2(1100, 1000), SIMD2(1100, 1040), SIMD2(1000, 1040)
    ]

    private func makeParser() -> TileMvtParser {
        let config = ImmersiveMapSettings.default
        return TileMvtParser(
            determineFeatureStyle: DetermineFeatureStyle(mapStyle: ImmersiveMapTilesDefaultMapStyle()),
            labelProviderProfile: ImmersiveMapProviderRuntimeContext(settings: config).labelProviderProfile,
            config: config,
            glyphCoverage: .legacyAtlasForTests
        )
    }

    private func makeMesh(roofShape: RoofShape?,
                          interiors: [[SIMD2<Float>]] = []) -> TileMvtParser.ParsedExtrudedMesh? {
        let parser = makeParser()
        let roofVertices = rectangle.map { SIMD2<Int16>(Int16($0.x), Int16($0.y)) }
        let roofInfo = roofShape.map {
            RoofInfo(height: roofHeight, shape: $0, orientation: nil, directionDegrees: nil)
        }
        return parser.buildExtrudedMesh(clippedExterior: rectangle,
                                        clippedInteriors: interiors,
                                        roof: TileMvtParser.ParsedPolygon(vertices: roofVertices,
                                                                          indices: [0, 1, 2, 0, 2, 3]),
                                        roofInfo: roofInfo,
                                        baseHeight: 0,
                                        topHeight: topHeight,
                                        tileExtent: 4096)
    }

    /// Plan-view winding signs of the roof-surface triangles. The roof surface
    /// is the first surface appended, so its vertices carry surfaceID 1.
    private func roofWindingSigns(of mesh: TileMvtParser.ParsedExtrudedMesh) -> [Float] {
        var signs: [Float] = []
        var index = 0
        while index + 2 < mesh.indices.count {
            let v0 = mesh.vertices[Int(mesh.indices[index])]
            let v1 = mesh.vertices[Int(mesh.indices[index + 1])]
            let v2 = mesh.vertices[Int(mesh.indices[index + 2])]
            index += 3
            guard v0.surfaceID == 1, v1.surfaceID == 1, v2.surfaceID == 1 else { continue }
            let area = (v1.position.x - v0.position.x) * (v2.position.y - v0.position.y)
                - (v2.position.x - v0.position.x) * (v1.position.y - v0.position.y)
            if abs(area) > 0.001 {
                signs.append(area > 0 ? 1 : -1)
            }
        }
        return signs
    }

    func testShapedRoofsShareTheFlatLidWinding() throws {
        let flat = try XCTUnwrap(makeMesh(roofShape: nil))
        let flatSigns = roofWindingSigns(of: flat)
        XCTAssertFalse(flatSigns.isEmpty)
        let expected = try XCTUnwrap(flatSigns.first)
        XCTAssertTrue(flatSigns.allSatisfy { $0 == expected })

        for shape in [RoofShape.gabled, .hipped, .pyramid, .cone, .dome, .skillion] {
            let mesh = try XCTUnwrap(makeMesh(roofShape: shape))
            let signs = roofWindingSigns(of: mesh)
            XCTAssertFalse(signs.isEmpty, "\(shape) must produce a roof surface")
            XCTAssertTrue(signs.allSatisfy { $0 == expected },
                          "\(shape) roof triangles must match the flat lid's winding or culling hides them")
        }
    }

    func testGabledWallsRiseToTheRidgeAtGableEnds() throws {
        let mesh = try XCTUnwrap(makeMesh(roofShape: .gabled))
        // Walls carry surfaceIDs above the roof's. The gable-end walls sit on
        // x = 1000 and x = 1100 and must reach the ridge at the full height.
        let wallHeights = mesh.vertices
            .filter { $0.surfaceID > 1 && abs($0.position.x - 1000) < 0.01 }
            .map(\.position.z)
        XCTAssertEqual(try XCTUnwrap(wallHeights.max()), topHeight, accuracy: 0.01,
                       "The gable end must close as a vertical triangle up to the ridge")
    }

    func testRoofAcrossATileEdgeIsFramedByTheRawFootprint() throws {
        // The whole building runs from x = -40 to 60 (long axis X); this tile
        // only holds x in [0, 60]. Framed by the clipped piece alone the 60x40
        // piece would still be long in X here, so make it decisive: a raw
        // footprint whose ridge line must continue past the tile edge, and a
        // surface that stops exactly at x = 0 for the neighbouring tile to
        // pick up.
        let raw: [SIMD2<Float>] = [
            SIMD2(-40, 1000), SIMD2(60, 1000), SIMD2(60, 1040), SIMD2(-40, 1040)
        ]
        let clipped: [SIMD2<Float>] = [
            SIMD2(0, 1000), SIMD2(60, 1000), SIMD2(60, 1040), SIMD2(0, 1040)
        ]
        let parser = makeParser()
        let mesh = try XCTUnwrap(parser.buildExtrudedMesh(
            clippedExterior: clipped,
            clippedInteriors: [],
            unclippedExterior: raw,
            roof: TileMvtParser.ParsedPolygon(vertices: clipped.map { SIMD2<Int16>(Int16($0.x), Int16($0.y)) },
                                              indices: [0, 1, 2, 0, 2, 3]),
            roofInfo: RoofInfo(height: roofHeight, shape: .gabled, orientation: nil, directionDegrees: nil),
            baseHeight: 0,
            topHeight: topHeight,
            tileExtent: 4096))

        let roofVertices = mesh.vertices.filter { $0.surfaceID == 1 }
        XCTAssertFalse(roofVertices.isEmpty)
        for vertex in roofVertices {
            XCTAssertGreaterThanOrEqual(vertex.position.x, -0.01,
                                        "The roof surface must not spill past the tile edge")
        }
        let ridgeAtTheEdge = roofVertices.contains {
            abs($0.position.x) < 0.01 && abs($0.position.y - 1020) < 0.01
                && abs($0.position.z - topHeight) < 0.01
        }
        XCTAssertTrue(ridgeAtTheEdge,
                      "The ridge must reach the tile edge at full height, continuing into the neighbour tile")
    }

    func testGabledWithHolesFallsBackToAFlatLidAtFullHeight() throws {
        let hole: [SIMD2<Float>] = [
            SIMD2(1040, 1010), SIMD2(1060, 1010), SIMD2(1060, 1030), SIMD2(1040, 1030)
        ]
        let mesh = try XCTUnwrap(makeMesh(roofShape: .gabled, interiors: [hole]))
        let roofHeights = mesh.vertices.filter { $0.surfaceID == 1 }.map(\.position.z)
        XCTAssertFalse(roofHeights.isEmpty)
        for height in roofHeights {
            XCTAssertEqual(height, topHeight, accuracy: 0.01,
                           "An unshapeable footprint gets the honest flat lid, not a creased sheet")
        }
    }
}

/// The roof-shapes toggle (`StyleSettings.buildingRoofShapesEnabled`): off,
/// the parser never raises a shaped roof and every building takes the flat
/// lid at its full height. The flag is prepared-cache identity and a heavy
/// settings change, pinned alongside.
final class BuildingRoofShapesToggleTests: XCTestCase {
    private func makeParser(roofShapesEnabled: Bool) -> TileMvtParser {
        var config = ImmersiveMapSettings.default
        config.style.buildingRoofShapesEnabled = roofShapesEnabled
        return TileMvtParser(
            determineFeatureStyle: DetermineFeatureStyle(mapStyle: ImmersiveMapTilesDefaultMapStyle()),
            labelProviderProfile: ImmersiveMapProviderRuntimeContext(settings: config).labelProviderProfile,
            config: config,
            glyphCoverage: .legacyAtlasForTests
        )
    }

    private func heights(roofShapesEnabled: Bool) -> TileMvtParser.ExtrusionHeights? {
        let style = ImmersiveMapTilesDefaultMapStyle()
            .makeStyle(data: DetFeatureStyleData(layerName: "building",
                                                 properties: [:],
                                                 tile: Tile(x: 0, y: 0, z: 16)))
        let attributes: [String: MvtValue] = [
            "render_height": .float(20),
            "roof:shape": .string("gabled"),
            "roof:height": .float(6)
        ]
        return makeParser(roofShapesEnabled: roofShapesEnabled)
            .extrusionHeights(attributes: attributes, tileZoom: 16, style: style)
    }

    func testDisabledRoofShapesFallBackToTheFlatLid() throws {
        let shaped = try XCTUnwrap(heights(roofShapesEnabled: true))
        XCTAssertEqual(shaped.roof?.shape, .gabled, "Enabled roof shapes keep the shaped roof")
        let flat = try XCTUnwrap(heights(roofShapesEnabled: false))
        XCTAssertNil(flat.roof, "Disabled roof shapes never raise a shaped roof")
        XCTAssertEqual(flat.top, shaped.top, "The flat lid keeps the full building height")
    }

    func testTheFlagIsPreparedCacheIdentity() {
        func namespace(roofShapesEnabled: Bool) -> String {
            PreparedTileCacheIdentity(preparedFormatVersion: 84,
                                      styleRevision: 1,
                                      tileSourceRevision: 2,
                                      flatSeparateRoadRenderingMinimumZoom: 8,
                                      textRevision: 3,
                                      labelLanguage: .english,
                                      labelFallbackPolicy: .international,
                                      houseNumbersEnabled: true,
                                      houseNumbersMinimumZoom: 17,
                                      capitalMaximumZoom: 10,
                                      cityMaximumZoom: 12,
                                      smallSettlementMaximumZoom: 14,
                                      landmarkMinimumZoom: 15,
                                      addTestBorders: false,
                                      roofShapesEnabled: roofShapesEnabled).namespaceComponent
        }
        XCTAssertNotEqual(namespace(roofShapesEnabled: true), namespace(roofShapesEnabled: false),
                          "A tile prepared with flat lids must not answer a map that wants shaped roofs")
    }

    func testRoofShapesAreOffByDefault() {
        XCTAssertFalse(ImmersiveMapSettings.default.style.buildingRoofShapesEnabled)
    }

    func testTogglingTheFlagIsAHeavySettingsChange() {
        let old = ImmersiveMapSettings.default
        var new = old
        new.style.buildingRoofShapesEnabled = true
        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: old, to: new)
        XCTAssertTrue(plan.actions.contains(.rebuildPreparedData),
                      "Roof shapes are baked at parse time: the prepared tiles must rebuild")
        XCTAssertTrue(plan.actions.contains(.invalidateCaches))
        XCTAssertTrue(plan.requiresRendererRecreation)
    }
}
