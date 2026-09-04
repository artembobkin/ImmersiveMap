// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Foundation
import XCTest

/// The streetscape as a second, optional tile source: off by default, with
/// the default map drawing no road paint; on, a second tile per coordinate
/// at street zoom, folded into the road layer before parsing.
final class StreetscapeTests: XCTestCase {
    private let tile = Tile(x: 39615, y: 20486, z: 16)

    private func makeParser(streetscape: Bool) -> TileMvtParser {
        let config = ImmersiveMapSettings.default.streetscape(isEnabled: streetscape)
        let runtimeContext = ImmersiveMapProviderRuntimeContext(settings: config)
        return TileMvtParser(determineFeatureStyle: DetermineFeatureStyle(mapStyle: runtimeContext.mapStyle),
                             labelProviderProfile: runtimeContext.labelProviderProfile,
                             config: config,
                             glyphCoverage: .legacyAtlasForTests)
    }

    private func parse(_ data: Data, streetscape: Bool) throws -> TileMvtParser.ParsedTile {
        try makeParser(streetscape: streetscape).parse(tile: tile, mvtData: data)
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

    // MARK: - Default off: a street map with no paint on the asphalt

    func testTheDefaultMapDrawsAStreetAsCasingAndFillWithoutLanePaint() throws {
        let data = VectorTileFixture.layerTile(layerName: "transportation", features: [street()])
        let bare = try parse(data, streetscape: false).drawingRoadPhases.automobileGround
        XCTAssertGreaterThan(bare.fill.drawing.indices.count, 0, "The asphalt draws")
        XCTAssertEqual(bare.detail.drawing.indices.count, 0,
                       "and no centre divider is synthesized from the lane count")

        let painted = try parse(data, streetscape: true).drawingRoadPhases.automobileGround
        XCTAssertGreaterThan(painted.detail.drawing.indices.count, 0,
                             "With the streetscape on, the four-lane two-way street is painted down the middle")
    }

    func testTheDefaultMapKeepsAParkingLotAsAsphaltWithoutTheComb() throws {
        let data = VectorTileFixture.layerTile(layerName: "transportation", features: [parkingLot])
        let bare = try parse(data, streetscape: false).drawingRoadPhases.automobileGround
        XCTAssertGreaterThan(bare.fill.drawing.indices.count, 0, "The lot's asphalt draws")
        XCTAssertGreaterThan(bare.casing.drawing.indices.count, 0, "with its kerb")
        XCTAssertEqual(bare.detail.drawing.indices.count, 0, "and no parking-bay comb")

        let painted = try parse(data, streetscape: true).drawingRoadPhases.automobileGround
        XCTAssertGreaterThan(painted.detail.drawing.indices.count, 0, "The comb is a streetscape feature")
    }

    func testTheDefaultMapDrawsNothingForAShippedMarking() throws {
        let data = VectorTileFixture.layerTile(layerName: "transportation", features: [dividingLine])
        let bare = try parse(data, streetscape: false)
        let auto = bare.drawingRoadPhases.automobileGround
        XCTAssertEqual(auto.detail.drawing.indices.count, 0, "No paint")
        XCTAssertEqual(auto.fill.drawing.indices.count, 0,
                       "and no fill ribbon in the paint's colour standing in for it")
        XCTAssertEqual(bare.drawingRoadPhases.ground.fill.drawing.indices.count, 0)

        let painted = try parse(data, streetscape: true).drawingRoadPhases.automobileGround
        XCTAssertGreaterThan(painted.detail.drawing.indices.count, 0, "With the streetscape on it draws")
    }

    func testTheDefaultMapKeepsTheCrossingReadOffTheRoadsAttributes() throws {
        let data = VectorTileFixture.layerTile(layerName: "transportation", features: [markedCrossing])
        let bare = try parse(data, streetscape: false).drawingRoadPhases.automobileGround
        XCTAssertGreaterThan(bare.detail.drawing.indices.count, 0,
                             "A marked crossing is part of a street map, streetscape or not")
    }

    func testStrippingRoadPaintLeavesAGroundStyleAlone() {
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: .immersiveMapTilesDefault)
        let water = style.makeStyle(data: DetFeatureStyleData(layerName: "water", properties: [:], tile: tile))
        XCTAssertEqual(water.strippingRoadPaint().key, water.key)
        XCTAssertEqual(water.strippingRoadPaint().color, water.color)
    }

    // MARK: - The streetscape layer folds into the road layer

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

    func testTheStreetscapeLayerFoldsIntoTheRoadLayerWithItsAttributesIntact() throws {
        let data = VectorTileFixture.layersTile([
            (layerName: "water", features: [.init(id: 9, geometry: .polygon(ring: [(0, 0), (100, 0), (100, 100), (0, 100)]), properties: ["class": "lake"])]),
            (layerName: "transportation", features: [street()]),
            (layerName: "streetscape", features: [surface, dividingLine]),
        ])
        let folded = MvtRoadLayerFold.foldingStreetscapeLayers(try MvtTileDecoder.decode(data: data))
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
        let folded = MvtRoadLayerFold.foldingStreetscapeLayers(try MvtTileDecoder.decode(data: data))
        XCTAssertEqual(folded.layers.map(\.name), ["streetscape"])

        let parsed = try parse(data, streetscape: true).drawingRoadPhases.automobileGround
        XCTAssertGreaterThan(parsed.fill.drawing.indices.count, 0, "The surface draws in the automobile tier")
        XCTAssertGreaterThan(parsed.detail.drawing.indices.count, 0, "and the paint on it")
    }

    func testTheSurfaceFromTheStreetscapeLayerClipsTheStreetFromTheMapLayer() throws {
        let streetOnly = VectorTileFixture.layerTile(layerName: "transportation", features: [street()])
        let both = VectorTileFixture.layersTile([
            (layerName: "transportation", features: [street()]),
            (layerName: "streetscape", features: [surface]),
        ])
        let alone = try parse(streetOnly, streetscape: true).drawingRoadPhases.automobileGround
        let clipped = try parse(both, streetscape: true).drawingRoadPhases.automobileGround
        XCTAssertGreaterThan(clipped.fill.drawing.indices.count, alone.fill.drawing.indices.count,
                             "The surface polygon draws in the fill phase next to the ribbon")
        XCTAssertGreaterThan(clipped.fill.drawing.vertices.count, alone.fill.drawing.vertices.count)
    }

    func testTheStyleReadsTheStreetscapeLayerByTheRoadRules() {
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: .immersiveMapTilesDefault)
        let properties: [String: MvtValue] = ["marking": .string("dividing"),
                                              "style": .string("dashed"),
                                              "paint": .string("white")]
        let viaStreetscape = style.makeStyle(data: DetFeatureStyleData(layerName: "streetscape", properties: properties, tile: tile))
        let viaTransportation = style.makeStyle(data: DetFeatureStyleData(layerName: "transportation", properties: properties, tile: tile))
        XCTAssertEqual(viaStreetscape.key, viaTransportation.key)
        XCTAssertTrue(viaStreetscape.isShippedRoadPaint)
    }

    // MARK: - Settings

    func testTheHostedSourceDerivesTheStreetscapeTemplate() {
        let settings = ImmersiveMapSettings.default.streetscape(isEnabled: true)
        XCTAssertEqual(settings.tiles.streetscape.resolvedTileURLTemplate(network: settings.tiles.network),
                       ImmersiveMapTilesService.streetscapeTileURLTemplate)

        let keyed = ImmersiveMapSettings.default
            .tileURLTemplate("https://immersivemap.dev/tiles/{z}/{x}/{y}.mvt?key=abc")
            .streetscape(isEnabled: true)
        XCTAssertEqual(keyed.tiles.streetscape.resolvedTileURLTemplate(network: keyed.tiles.network),
                       ImmersiveMapTilesService.streetscapeTileURLTemplate + "?key=abc",
                       "A key in the map template's query travels to the streetscape archive")
    }

    func testACustomSourceNeedsItsOwnStreetscapeTemplate() {
        let custom = ImmersiveMapSettings.default
            .tileURLTemplate("https://tiles.example/{z}/{x}/{y}.mvt")
            .streetscape(isEnabled: true)
        XCTAssertNil(custom.tiles.streetscape.resolvedTileURLTemplate(network: custom.tiles.network))

        let stated = custom.streetscapeTileURLTemplate("https://tiles.example/streetscape/{z}/{x}/{y}.mvt")
        XCTAssertEqual(stated.tiles.streetscape.resolvedTileURLTemplate(network: stated.tiles.network),
                       "https://tiles.example/streetscape/{z}/{x}/{y}.mvt")

        let off = ImmersiveMapSettings.default.streetscapeTileURLTemplate("https://tiles.example/s/{z}/{x}/{y}.mvt")
        XCTAssertFalse(off.tiles.streetscape.isEnabled, "Naming the template does not turn the streetscape on")
        XCTAssertNil(off.tiles.streetscape.resolvedTileURLTemplate(network: off.tiles.network))
    }

    func testTheStreetscapeIsPreparedCacheIdentityButNotTileSourceIdentity() {
        let off = ImmersiveMapSettings.default
        let on = off.streetscape(isEnabled: true)
        XCTAssertEqual(PreparedTileCacheIdentity.streetscapeRevision(for: off.tiles), 0)
        XCTAssertNotEqual(PreparedTileCacheIdentity.streetscapeRevision(for: on.tiles), 0)
        XCTAssertEqual(PreparedTileCacheIdentity.tileSourceRevision(for: off.tiles.network),
                       PreparedTileCacheIdentity.tileSourceRevision(for: on.tiles.network),
                       "Downloaded offline regions are namespaced by the map tiles alone")

        func namespace(streetscapeRevision: UInt64) -> String {
            PreparedTileCacheIdentity(preparedFormatVersion: PreparedTileDiskCaching.preparedFormatVersion,
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
                                      roofShapesEnabled: true,
                                      streetscapeRevision: streetscapeRevision).namespaceComponent
        }
        XCTAssertNotEqual(namespace(streetscapeRevision: 0), namespace(streetscapeRevision: 7),
                          "A tile prepared without the streetscape must not answer a map that wants it")
    }

    func testTogglingTheStreetscapeRebuildsThePipelineAndWhatItPrepared() {
        let oldSettings = ImmersiveMapSettings.default
        let newSettings = oldSettings.streetscape(isEnabled: true)
        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)
        XCTAssertEqual(plan.changedDomains, [.tiles])
        XCTAssertEqual(plan.actions, [.invalidateCaches, .rebuildPreparedData, .recreateRenderer])
    }

    // MARK: - Merging the two downloads

    func testTheMergeConcatenatesTheTwoTilesUnderAnETagNamingBoth() {
        let map = Data([1, 2, 3])
        let overlay = Data([4, 5])
        XCTAssertEqual(TileStreetscapeMerge.merge(map: .success(map, etag: "a"),
                                                  streetscape: .success(overlay, etag: "b")),
                       .success(Data([1, 2, 3, 4, 5]), etag: "a|b"))
        XCTAssertEqual(TileStreetscapeMerge.merge(map: .success(map, etag: "a"),
                                                  streetscape: .success(overlay, etag: nil)),
                       .success(Data([1, 2, 3, 4, 5]), etag: nil),
                       "Without both ETags the merged bytes cannot prove their freshness")
    }

    func testAnAbsentStreetscapeTileLeavesTheMapTileAlone() {
        let map = Data([1, 2, 3])
        for absent in [TileDownloader.DownloadResult.failure(.notFound), .failure(.gone), .failure(.emptyBody)] {
            XCTAssertEqual(TileStreetscapeMerge.merge(map: .success(map, etag: "a"), streetscape: absent),
                           .success(map, etag: "a|-"))
        }
        XCTAssertEqual(TileStreetscapeMerge.merge(map: .success(map, etag: "a"), streetscape: nil),
                       .success(map, etag: "a|-"))
    }

    func testAFailedStreetscapeRequestFailsTheTile() {
        let map = Data([1, 2, 3])
        for failure in [TileDownloader.DownloadFailure.network, .forbidden, .unauthorized,
                        .server(statusCode: 503), .rateLimited(retryAfter: nil), .client(statusCode: 418)] {
            XCTAssertEqual(TileStreetscapeMerge.merge(map: .success(map, etag: "a"), streetscape: .failure(failure)),
                           .failure(failure),
                           "A key the archive is not handed out to, or a passing failure, must not cache a bare tile")
        }
        XCTAssertEqual(TileStreetscapeMerge.merge(map: .failure(.network), streetscape: .success(Data([4]), etag: "b")),
                       .failure(.network))
    }
}
