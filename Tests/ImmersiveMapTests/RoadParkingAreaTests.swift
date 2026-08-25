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

        // z15 is the level the lot itself ships at, and a lot draws the same
        // there as at z16: same asphalt, same kerb, same comb. The tile level
        // decides the resolution of the polygon, not what is painted on it.
        let coarse = makeStyle(z: 15)
        XCTAssertTrue(coarse.isRoadSurfaceArea, "At z15 the lot is still asphalt with a kerb")
        XCTAssertEqual(coarse.resolvedLineRenderPasses.map(\.roadPassRole),
                       lot.resolvedLineRenderPasses.map(\.roadPassRole),
                       "and it keeps the comb: a lot looks the same at z15 as at z16")

        let regional = makeStyle(z: 14)
        XCTAssertFalse(regional.resolvedLineRenderPasses.contains { $0.roadPassRole == .detail },
                       "Below the level the lot ships at there is nothing to comb")
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

        // And the same lot combs itself a tile level out, where the camera
        // between zoom 15 and 16 is served from.
        let coarse = try parse([lot()], z: 15)
        XCTAssertGreaterThan(coarse.drawingRoadPhases.automobileGround.detail.drawing.indices.count, 0,
                             "The comb is built at z15 too")
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

    func testAParkingLotDoesNotEatTheServiceRoadsPassingAlongIt() throws {
        // A dedicated bus lane is often mapped as its own service way along
        // the kerb, inside the parking polygon's reach. The lot owns its
        // aisles, not the through service tier.
        let busWay = VectorTileFixture.Feature(id: 3,
                                               geometry: .line(points: [(1600, 1850), (2600, 1850)]),
                                               properties: ["class": "service"])
        let together = try parse([lot(), busWay])
        let lotOnly = try parse([lot()])
        XCTAssertGreaterThan(together.drawingRoadPhases.automobileGround.fill.drawing.indices.count,
                             lotOnly.drawingRoadPhases.automobileGround.fill.drawing.indices.count,
                             "A through service road keeps its ribbon across the lot")
    }

    func testTheCombEndsAtAnOverlappingCarriageway() throws {
        // A carriageway polygon over the right half of the lot: that ground
        // is the road's, and the comb must not climb onto it.
        let roadway = VectorTileFixture.Feature(id: 4,
                                                geometry: .polygon(ring: [(2100, 1700), (2800, 1700), (2800, 2200), (2100, 2200)]),
                                                properties: ["class": "primary", "subclass": "carriageway_area", "origin": "graph"])
        let together = try parse([lot(), roadway])
        let lotOnly = try parse([lot()])
        XCTAssertLessThan(together.drawingRoadPhases.automobileGround.detail.drawing.indices.count,
                          lotOnly.drawingRoadPhases.automobileGround.detail.drawing.indices.count,
                          "The stripes over the roadway are gone")
        XCTAssertGreaterThan(together.drawingRoadPhases.automobileGround.detail.drawing.indices.count, 0,
                             "and the rest of the comb survives")
    }

    func testADedicatedBusLaneIsTheLetterANotATone() throws {
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: .immersiveMapTilesDefault)
        func value(_ v: String) -> VectorTile_Tile.Value { var x = VectorTile_Tile.Value(); x.stringValue = v; return x }
        let lane = style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                             properties: ["marking": value("bus_lane")],
                                                             tile: Tile(x: 39615, y: 20486, z: 16)))
        XCTAssertEqual(lane.roadDecorationKind, .busLaneLetter,
                       "The lane's axis carries the letter A, not a recolored surface")
        XCTAssertTrue(lane.isShippedRoadPaint, "and the axis is measured paint the machinery leaves alone")
        let coarse = style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                               properties: ["marking": value("bus_lane")],
                                                               tile: Tile(x: 19807, y: 10243, z: 15)))
        XCTAssertEqual(coarse.key, lane.key, "and it is stamped at z15 exactly as at z16")
        let regional = style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                                 properties: ["marking": value("bus_lane")],
                                                                 tile: Tile(x: 9903, y: 5121, z: 14)))
        XCTAssertEqual(regional.key, 0, "Below the measured street's own level there is no lane to mark")
        let polygon = style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                                properties: ["subclass": value("bus_lane_area")],
                                                                tile: Tile(x: 39615, y: 20486, z: 16)))
        XCTAssertEqual(polygon.key, 0, "The older toned polygon draws nothing")

        // A lane axis across the tile stamps its letters into the detail
        // phase as polygons.
        let parsed = try parse([.init(id: 7,
                                      geometry: .line(points: [(500, 2900), (3600, 2900)]),
                                      properties: ["marking": "bus_lane"])])
        XCTAssertGreaterThan(parsed.drawingRoadPhases.automobileGround.detail.drawing.indices.count, 0,
                             "The letters draw above the carriageway")
    }

    func testABusStopWearsTheYellowSawtooth() throws {
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: .immersiveMapTilesDefault)
        func value(_ v: String) -> VectorTile_Tile.Value { var x = VectorTile_Tile.Value(); x.stringValue = v; return x }
        let stop = style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                             properties: ["marking": value("bus_stop_zigzag")],
                                                             tile: Tile(x: 39615, y: 20486, z: 16)))
        XCTAssertEqual(stop.roadDecorationKind, .busStopZigzag)
        XCTAssertTrue(stop.isShippedRoadPaint)
        XCTAssertGreaterThan(stop.color.x, stop.color.z, "The stop marking is yellow, not white")
        let coarse = style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                               properties: ["marking": value("bus_stop_zigzag")],
                                                               tile: Tile(x: 19807, y: 10243, z: 15)))
        XCTAssertEqual(coarse.key, stop.key, "and it folds at z15 exactly as at z16")
        let regional = style.makeStyle(data: DetFeatureStyleData(layerName: "transportation",
                                                                 properties: ["marking": value("bus_stop_zigzag")],
                                                                 tile: Tile(x: 9903, y: 5121, z: 14)))
        XCTAssertEqual(regional.key, 0, "Below the measured street's own level there is no kerb to fold along")
        let parsed = try parse([.init(id: 8,
                                      geometry: .line(points: [(500, 3200), (700, 3200)]),
                                      properties: ["marking": "bus_stop_zigzag"])])
        XCTAssertGreaterThan(parsed.drawingRoadPhases.automobileGround.detail.drawing.indices.count, 0,
                             "The sawtooth draws above the carriageway")
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
