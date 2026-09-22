// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
@testable import ImmersiveMap
import Mvt
import XCTest

/// The streetscape is what a tile carries: where the road layer ships
/// reconstructed carriageway surfaces and measured paint, they draw on the
/// roads' symbols with the crossings striped; where it does not, the map is
/// the symbols alone, with no carriageway to stripe.
final class StreetscapeTests: XCTestCase {
    private let tile = Tile(x: 39615, y: 20486, z: 16)

    private func parse(_ data: Data) throws -> ParsedTile {
        try TileMvtParser.forTests(settings: .default).parse(tile: tile, mvtData: data)
    }

    /// The same features in a tile that also carries the streetscape.
    private func parse(withStreetscape features: [VectorTileFixture.Feature]) throws -> ParsedTile {
        try parse(VectorTileFixture.layerTile(layerName: "transportation", features: features + [.streetscapeMarker]))
    }

    private func street(lanes: String = "4", extra: [String: String] = [:]) -> VectorTileFixture.Feature {
        var properties = ["class": "primary", "lanes": lanes, "lanes_src": "tagged", "name": "Tverskaya Street"]
        for (key, value) in extra { properties[key] = value }
        return .init(id: 2, geometry: .line(points: [(1200, 1050), (2900, 1050)]), properties: properties)
    }

    private var surface: VectorTileFixture.Feature {
        .init(id: 1,
              geometry: .polygon(ring: [(1800, 800), (2600, 800), (2600, 1300), (1800, 1300)]),
              properties: ["class": "primary", "subclass": "carriageway_area", "origin": "graph"])
    }

    private var dividingLine: VectorTileFixture.Feature {
        .init(id: 3,
              geometry: .line(points: [(1850, 1050), (2550, 1050)]),
              properties: ["marking": "dividing", "style": "dashed", "paint": "white"])
    }

    private var parkingLot: VectorTileFixture.Feature {
        .init(id: 4,
              geometry: .polygon(ring: [(400, 2400), (1400, 2400), (1400, 3000), (400, 3000)]),
              properties: ["class": "service", "subclass": "parking_area"])
    }

    private var markedCrossing: VectorTileFixture.Feature {
        .init(id: 5,
              geometry: .line(points: [(2048, 900), (2048, 1200)]),
              properties: ["class": "path", "subclass": "footway", "crossing": "marked"])
    }

    // MARK: - A tile without the streetscape is a street map

    func testAStreetAloneIsCasingAndFillWithoutLanePaint() throws {
        let data = VectorTileFixture.layerTile(layerName: "transportation", features: [street()])
        let bare = try parse(data).drawingRoadPhases.automobileGround
        XCTAssertGreaterThan(bare.fill.drawing.indices.count, 0, "The asphalt draws")
        XCTAssertEqual(bare.detail.drawing.indices.count, 0,
                       "and no centre divider is synthesized from the lane count")

        let painted = try parse(withStreetscape: [street()]).drawingRoadPhases.automobileGround
        XCTAssertGreaterThan(painted.detail.drawing.indices.count, 0,
                             "In a tile with the streetscape, the four-lane two-way street is painted down the middle")
    }

    func testAParkingLotIsAStreetscapeFigure() throws {
        let data = VectorTileFixture.layerTile(layerName: "transportation", features: [parkingLot])
        let bare = try parse(data).drawingRoadPhases.automobileGround
        XCTAssertEqual(bare.fill.drawing.indices.count, 0,
                       "Without the streetscape the roads are lines only: no lot asphalt")
        XCTAssertEqual(bare.casing.drawing.indices.count, 0, "no kerb")
        XCTAssertEqual(bare.detail.drawing.indices.count, 0, "and no parking-bay comb")

        let painted = try parse(withStreetscape: [parkingLot]).drawingRoadPhases.automobileGround
        XCTAssertGreaterThan(painted.fill.drawing.indices.count, 0, "With the streetscape the lot's asphalt draws")
        XCTAssertGreaterThan(painted.casing.drawing.indices.count, 0, "with its kerb")
        XCTAssertGreaterThan(painted.detail.drawing.indices.count, 0, "and the comb")
    }

    func testAHandMappedSurfaceNeverDrawsWithoutTheStreetscape() throws {
        let area = VectorTileFixture.Feature(
            id: 6,
            geometry: .polygon(ring: [(1800, 800), (2600, 800), (2600, 1300), (1800, 1300)]),
            // A junction area without `origin=graph`: mapped by hand.
            properties: ["class": "primary", "subclass": "junction_area"])
        let data = VectorTileFixture.layerTile(layerName: "transportation", features: [area])
        let bare = try parse(data).drawingRoadPhases.automobileGround
        XCTAssertEqual(bare.fill.drawing.indices.count, 0, "A road polygon is not a line")
    }

    func testMeasuredPaintMakesATileAStreetscapeTile() throws {
        let data = VectorTileFixture.layerTile(layerName: "transportation", features: [dividingLine])
        let painted = try parse(data).drawingRoadPhases.automobileGround
        XCTAssertGreaterThan(painted.detail.drawing.indices.count, 0, "The measured line draws as paint")
        XCTAssertEqual(painted.fill.drawing.indices.count, 0,
                       "and no fill ribbon in the paint's colour stands in for it")
    }

    func testAMarkedCrossingIsAStreetscapeFigure() throws {
        let data = VectorTileFixture.layerTile(layerName: "transportation", features: [markedCrossing])
        let bare = try parse(data).drawingRoadPhases.automobileGround
        XCTAssertEqual(bare.detail.drawing.indices.count, 0,
                       "Without the streetscape there is no carriageway to paint a zebra on")

        let painted = try parse(withStreetscape: [markedCrossing]).drawingRoadPhases.automobileGround
        XCTAssertGreaterThan(painted.detail.drawing.indices.count, 0,
                             "With the streetscape the tagged crossing is striped")
    }

    // MARK: - The streetscape layer merges into the road layer

    private func attributes(of feature: MvtDecodedFeature, in layer: MvtDecodedLayer, data: Data) -> [String: MvtValue] {
        let tags = feature.tags.materializedValues(data: data)
        var attributes: [String: MvtValue] = [:]
        var index = 0
        while index + 1 < tags.count {
            attributes[layer.keys[Int(tags[index])]] = layer.values[Int(tags[index + 1])]
            index += 2
        }
        return attributes
    }

    /// The decoder's merge of the streetscape into the road layer, by the
    /// hosted tiles' layer names.
    private func fold(_ tile: MvtDecodedTile) -> MvtDecodedTile {
        tile.merging(layersNamed: "streetscape", intoFirstLayerNamed: ["transportation"])
    }

    func testTheStreetscapeLayerFoldsIntoTheRoadLayerWithItsAttributesIntact() throws {
        let data = VectorTileFixture.layersTile([
            (layerName: "water", features: [.init(id: 9, geometry: .polygon(ring: [(0, 0), (100, 0), (100, 100), (0, 100)]), properties: ["class": "lake"])]),
            (layerName: "transportation", features: [street()]),
            (layerName: "streetscape", features: [surface, dividingLine]),
        ])
        let folded = try fold(MvtTileDecoder.decode(data: data))
        XCTAssertEqual(folded.layers.map(\.name), ["water", "transportation"],
                       "The streetscape layer is gone, folded into the road layer, and the order of the rest holds")
        let road = folded.layers[1]
        XCTAssertEqual(road.features.count, 3)
        let readBack = road.features.map { attributes(of: $0, in: road, data: data) }
        XCTAssertEqual(readBack[0]["name"]?.stringValue, "Tverskaya Street")
        XCTAssertEqual(readBack[1]["subclass"]?.stringValue, "carriageway_area")
        XCTAssertEqual(readBack[1]["origin"]?.stringValue, "graph")
        XCTAssertEqual(readBack[2]["marking"]?.stringValue, "dividing")
        XCTAssertEqual(readBack[2]["paint"]?.stringValue, "white")
    }

    func testAStreetscapeLayerWithNoRoadLayerStaysItsOwnLayerAndStillDrawsAsRoads() throws {
        let data = VectorTileFixture.layerTile(layerName: "streetscape", features: [surface, dividingLine])
        let folded = fold(try MvtTileDecoder.decode(data: data))
        XCTAssertEqual(folded.layers.map(\.name), ["streetscape"])

        let parsed = try parse(data).drawingRoadPhases.automobileGround
        XCTAssertGreaterThan(parsed.fill.drawing.indices.count, 0, "The surface draws in the automobile tier")
        XCTAssertGreaterThan(parsed.detail.drawing.indices.count, 0, "and the paint on it")
    }

    func testTheSurfaceFromTheStreetscapeLayerClipsTheStreetFromTheMapLayer() throws {
        let both = VectorTileFixture.layersTile([
            (layerName: "transportation", features: [street()]),
            (layerName: "streetscape", features: [surface]),
        ])
        let alone = try parse(withStreetscape: [street()]).drawingRoadPhases.automobileGround
        let clipped = try parse(both).drawingRoadPhases.automobileGround
        XCTAssertGreaterThan(clipped.fill.drawing.indices.count, alone.fill.drawing.indices.count,
                             "The surface polygon draws in the fill phase next to the ribbon")
        XCTAssertGreaterThan(clipped.fill.drawing.vertices.count, alone.fill.drawing.vertices.count)
    }

    func testTheStyleReadsTheStreetscapeLayerByTheRoadRules() {
        let style = ImmersiveMapTilesDefaultMapStyle(theme: .default)
        let properties: [String: MvtValue] = ["marking": .string("dividing"),
                                              "style": .string("dashed"),
                                              "paint": .string("white")]
        let viaStreetscape = style.makeStyle(data: DetFeatureStyleData(layerName: "streetscape", properties: properties, tile: tile))
        let viaTransportation = style.makeStyle(data: DetFeatureStyleData(layerName: "transportation", properties: properties, tile: tile))
        XCTAssertEqual(viaStreetscape.key, viaTransportation.key)
        XCTAssertTrue(ImmersiveMapTilesSchema().facts(layerName: "streetscape", properties: properties, tile: tile).road?.isShippedPaint == true)
    }
}
