// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// A surface parking lot (`subclass=parking_area`, a polygon in
/// `transportation`) draws as service-tier asphalt with a kerb, exactly like
/// a junction area, and from street zoom its detail phase carries the
/// synthesized comb of parking-bay stripes. The surface clips the ribbons
/// inside it (a parking aisle needs no kerb across the lot) and never cuts
/// anyone's paint.
final class RoadParkingAreaTests: XCTestCase {
    private func makeParser() -> TileMvtParser {
        let config = ImmersiveMapSettings.default
        let runtimeContext = ImmersiveMapProviderRuntimeContext(settings: config)
        return TileMvtParser(determineFeatureStyle: DetermineFeatureStyle(mapStyle: runtimeContext.mapStyle),
                             labelProviderProfile: runtimeContext.labelProviderProfile,
                             config: config,
                             glyphCoverage: .legacyAtlasForTests)
    }

    private func makeStyle(z: Int, extra: [String: String] = [:]) -> FeatureStyle {
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: .immersiveMapTilesDefault)
        var props: [String: VectorTile_Tile.Value] = [:]
        var subclassValue = VectorTile_Tile.Value(); subclassValue.stringValue = "parking_area"
        props["subclass"] = subclassValue
        for (key, value) in extra {
            var v = VectorTile_Tile.Value(); v.stringValue = value
            props[key] = v
        }
        let scale = 1 << max(0, 16 - z)
        return style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                         properties: props,
                                                         tile: Tile(x: 39615 / scale, y: 20486 / scale, z: z)))
    }

    func testAParkingLotIsServiceAsphaltWithAKerbAndACombFromStreetZoom() {
        let lot = makeStyle(z: 16)
        XCTAssertTrue(lot.isRoadSurfaceArea, "A parking lot is a carriageway surface")
        XCTAssertFalse(lot.surfaceAreaCutsPaint, "and it cuts nobody's paint")
        XCTAssertEqual(lot.roadDecorationKind, .parkingBays)
        let roles = lot.resolvedLineRenderPasses.map(\.roadPassRole)
        XCTAssertTrue(roles.contains(.fill), "The asphalt")
        XCTAssertTrue(roles.contains(.casing), "the kerb on its outline")
        XCTAssertTrue(roles.contains(.detail), "and the bay comb at street zoom")
        let service = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault.layers.roads.service
        XCTAssertEqual(lot.resolvedLineRenderPasses.first { $0.roadPassRole == .fill }?.color, service,
                       "The lot merges into the service tier it belongs to")

        let coarse = makeStyle(z: 15)
        XCTAssertTrue(coarse.isRoadSurfaceArea, "At z15 the lot is still asphalt with a kerb")
        XCTAssertFalse(coarse.resolvedLineRenderPasses.contains { $0.roadPassRole == .detail },
                       "but a 2.6 m bay is a couple of pixels there: no comb")
    }

    private let lotRing: [(Int32, Int32)] = [(1500, 1800), (2700, 1800), (2700, 2100), (1500, 2100)]

    private func parse(_ features: [VectorTileFixture.Feature], z: Int = 16) throws -> TileMvtParser.ParsedTile {
        let scale = 1 << max(0, 16 - z)
        return try makeParser().parse(tile: Tile(x: 39615 / scale, y: 20486 / scale, z: z),
                                      mvtData: VectorTileFixture.layerTile(layerName: "transportation",
                                                                           features: features))
    }

    private func lot(extra: [String: String] = [:]) -> VectorTileFixture.Feature {
        var properties = ["subclass": "parking_area"]
        for (key, value) in extra { properties[key] = value }
        return .init(id: 1, geometry: .polygon(ring: lotRing), properties: properties)
    }

    func testAParkingLotDrawsFillKerbAndCombInTheAutomobileTier() throws {
        let parsed = try parse([lot()])
        let auto = parsed.drawingRoadPhases.automobileGround
        XCTAssertGreaterThan(auto.fill.drawing.indices.count, 0, "The asphalt draws")
        XCTAssertGreaterThan(auto.casing.drawing.indices.count, 0, "the kerb draws")
        XCTAssertGreaterThan(auto.detail.drawing.indices.count, 0, "and the comb draws above them")
        XCTAssertEqual(parsed.drawingRoadPhases.ground.fill.drawing.indices.count, 0,
                       "nothing falls to the pedestrian tier")
    }

    func testAParkingAisleInsideTheLotLosesItsOwnRibbon() throws {
        let aisle = VectorTileFixture.Feature(id: 2,
                                              geometry: .line(points: [(1600, 1950), (2600, 1950)]),
                                              properties: ["class": "service", "service": "parking_aisle"])
        let together = try parse([lot(), aisle])
        let lotOnly = try parse([lot()])
        XCTAssertEqual(together.drawingRoadPhases.automobileGround.fill.drawing.indices.count,
                       lotOnly.drawingRoadPhases.automobileGround.fill.drawing.indices.count,
                       "The aisle inside the lot is the lot's own asphalt, not a second ribbon")
        XCTAssertEqual(together.drawingRoadPhases.automobileGround.casing.drawing.indices.count,
                       lotOnly.drawingRoadPhases.automobileGround.casing.drawing.indices.count,
                       "and it wears no kerb of its own across the lot")
    }

    func testTheCombStaysInsideTheLot() throws {
        let parsed = try parse([lot()])
        let detail = parsed.drawingRoadPhases.automobileGround.detail
        XCTAssertGreaterThan(detail.drawing.vertices.count, 0)
        // Render space: y is flipped, the lot spans y 4096-2100...4096-1800.
        for vertex in detail.drawing.vertices {
            XCTAssertTrue((1490...2710).contains(Int(vertex.position.x)),
                          "A stripe stays on the lot: x=\(vertex.position.x)")
            XCTAssertTrue((1986...2306).contains(Int(vertex.position.y)),
                          "A stripe stays on the lot: y=\(vertex.position.y)")
        }
    }
}
