// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class TileMvtParserFallbackLabelTests: XCTestCase {
    func testFrenchPreferencesFallBackToEnglishWhenAccentedFallbackWaterLabelIsUnsupported() throws {
        let labels = try parseFallbackWaterLabels(language: .french)

        XCTAssertTrue(labels.contains("Atlantic Ocean"))
        XCTAssertFalse(labels.contains("Océan Atlantique"))
    }

    func testGermanPreferencesResolveRenderableFallbackWaterLabel() throws {
        let labels = try parseFallbackWaterLabels(language: .german)

        XCTAssertTrue(labels.contains("Atlantischer Ozean"))
        XCTAssertFalse(labels.contains("Atlantic Ocean"))
    }

    func testGermanSouthernOceanFallsBackToEnglishWhenAccentedLabelIsUnsupported() throws {
        let labels = try parseFallbackWaterLabels(language: .german)

        XCTAssertTrue(labels.contains("Southern Ocean"))
        XCTAssertFalse(labels.contains("Südlicher Ozean"))
    }

    func testSpanishPreferencesFallBackToEnglishWhenAccentedFallbackWaterLabelIsUnsupported() throws {
        let labels = try parseFallbackWaterLabels(language: .spanish)

        XCTAssertTrue(labels.contains("Atlantic Ocean"))
        XCTAssertFalse(labels.contains("Océano Atlántico"))
    }

    func testSpanishSeaFallbackFallsBackToEnglishWhenAccentedLabelIsUnsupportedAtZoomTwo() throws {
        let labels = try parseFallbackWaterLabels(language: .spanish,
                                                  tile: Tile(x: 2, y: 1, z: 2))

        XCTAssertTrue(labels.contains("Mediterranean Sea"))
        XCTAssertFalse(labels.contains("Mar Mediterráneo"))
    }

    func testExistingProviderWaterAliasSuppressesLocalizedFallbackDuplicate() throws {
        let labels = try parseFallbackWaterLabels(language: .russian,
                                                  tile: Tile(x: 0, y: 0, z: 0),
                                                  mvtData: try makeProviderAtlanticOceanTile().serializedData(),
                                                  tileProvider: AnyImmersiveMapTileProvider(MapboxTileProvider(accessToken: nil)))

        XCTAssertEqual(labels.filter { $0 == "Atlantic Ocean" }.count, 1)
        XCTAssertFalse(labels.contains("Атлантический океан"))
    }

    func testPreferredFallbackWaterLabelWithUnsupportedGlyphsFallsBackToEnglish() throws {
        let asciiOnlyCoverage = VectorTileLabelGlyphCoverage(
            supportedScalars: Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 ".unicodeScalars.map(\.value))
        )
        let labels = try parseFallbackWaterLabels(language: .russian,
                                                  glyphCoverage: asciiOnlyCoverage)

        XCTAssertTrue(labels.contains("Atlantic Ocean"))
        XCTAssertFalse(labels.contains("Атлантический океан"))
    }

    func testEnglishAndRussianFallbackWaterLabelsRemainAvailable() throws {
        let englishLabels = try parseFallbackWaterLabels(language: .english)
        let russianLabels = try parseFallbackWaterLabels(language: .russian)

        XCTAssertTrue(englishLabels.contains("Atlantic Ocean"))
        XCTAssertTrue(russianLabels.contains("Атлантический океан"))
    }

    func testPublicLanguagePresetsHaveLocalizedFallbackWaterLabelsWithBundledAtlasCoverage() throws {
        let coverage = try Self.bundledGlyphCoverage()

        let italianLabels = try parseFallbackWaterLabels(language: .italian, glyphCoverage: coverage)
        let portugueseLabels = try parseFallbackWaterLabels(language: .portuguese, glyphCoverage: coverage)
        let turkishLabels = try parseFallbackWaterLabels(language: .turkish, glyphCoverage: coverage)

        XCTAssertTrue(italianLabels.contains("Oceano Atlantico"))
        XCTAssertTrue(portugueseLabels.contains("Oceano Atlântico"))
        XCTAssertTrue(turkishLabels.contains("Atlas Okyanusu"))
    }

    func testBundledAtlasCoverageAllowsLocalizedAccentedFallbackWaterLabels() throws {
        let labels = try parseFallbackWaterLabels(language: .french,
                                                  glyphCoverage: Self.bundledGlyphCoverage())

        XCTAssertTrue(labels.contains("Océan Atlantique"))
        XCTAssertFalse(labels.contains("Atlantic Ocean"))
    }

    func testExistingProviderWaterAliasSuppressesPortugueseFallbackDuplicate() throws {
        let labels = try parseFallbackWaterLabels(language: .portuguese,
                                                  tile: Tile(x: 0, y: 0, z: 0),
                                                  mvtData: try makeProviderAtlanticOceanTile(name: "Oceano Atlântico",
                                                                                            englishName: "Atlantic Ocean").serializedData(),
                                                  glyphCoverage: Self.bundledGlyphCoverage(),
                                                  fallbackPolicy: .localFirst,
                                                  tileProvider: AnyImmersiveMapTileProvider(MapboxTileProvider(accessToken: nil)))

        XCTAssertEqual(labels.filter { $0 == "Oceano Atlântico" }.count, 1)
        XCTAssertFalse(labels.contains("Atlantic Ocean"))
    }

    func testPointLabelsUseConfiguredProviderIDInRuntimeProfile() throws {
        var config = ImmersiveMapSettings.default
        config = config.tileProvider(ParserProviderIDTestTileProvider(id: "parser-provider"))

        let parser = TileMvtParser(determineFeatureStyle: DetermineFeatureStyle(mapStyle: FallbackWaterLabelStyle()),
                                   labelProviderProfile: ImmersiveMapProviderRuntimeContext(settings: config).labelProviderProfile,
                                   config: config,
                                   glyphCoverage: .legacyAtlasForTests)
        let parsedTile = try parser.parse(tile: Tile(x: 0, y: 0, z: 0),
                                          mvtData: try makeProviderAtlanticOceanTile().serializedData())
        let expectedKey = VectorTileLabelIdentity.providerFeature(providerID: "parser-provider",
                                                                  layerName: "natural_label",
                                                                  featureID: 1).runtimeKey
        let mapboxKey = VectorTileLabelIdentity.providerFeature(providerID: "mapbox",
                                                                layerName: "natural_label",
                                                                featureID: 1).runtimeKey

        XCTAssertTrue(parsedTile.textLabels.map(\.key).contains(expectedKey))
        XCTAssertFalse(parsedTile.textLabels.map(\.key).contains(mapboxKey))
    }

    func testParserNormalizesLayerExtentToInternalTileExtent() throws {
        let config = ImmersiveMapSettings.default
        let parser = TileMvtParser(determineFeatureStyle: DetermineFeatureStyle(mapStyle: ParserSolidPolygonStyle()),
                                   labelProviderProfile: ImmersiveMapProviderRuntimeContext(settings: config).labelProviderProfile,
                                   config: config,
                                   glyphCoverage: .legacyAtlasForTests)
        let parsedTile = try parser.parse(tile: Tile(x: 0, y: 0, z: 0),
                                          mvtData: try makeFullTilePolygonTile(extent: 2048).serializedData())
        let positions = parsedTile.drawingPolygon.vertices
            .filter { $0.styleIndex == 1 }
            .map(\.position)
        let maxX = positions.map(\.x).max()
        let maxY = positions.map(\.y).max()

        XCTAssertEqual(maxX, 4096)
        XCTAssertEqual(maxY, 4096)
    }

    func testParserSplitsComplexOceanHolesIntoBackgroundPolygons() throws {
        let config = ImmersiveMapSettings.default
        let parser = TileMvtParser(determineFeatureStyle: DetermineFeatureStyle(mapStyle: ParserSolidPolygonStyle()),
                                   labelProviderProfile: ImmersiveMapProviderRuntimeContext(settings: config).labelProviderProfile,
                                   config: config,
                                   glyphCoverage: .legacyAtlasForTests)
        let parsedTile = try parser.parse(tile: Tile(x: 0, y: 0, z: 0),
                                          mvtData: try makeComplexOceanTile().serializedData())
        let backgroundVertexCount = parsedTile.drawingPolygon.vertices
            .filter { $0.styleIndex == 0 }
            .count
        let oceanVertexCount = parsedTile.drawingPolygon.vertices
            .filter { $0.styleIndex == 1 }
            .count

        XCTAssertGreaterThan(backgroundVertexCount, 65 * 65)
        XCTAssertGreaterThan(oceanVertexCount, 0)
    }

    private func makeFullTilePolygonTile(extent: UInt32) -> VectorTile_Tile {
        var feature = VectorTile_Tile.Feature()
        feature.id = 1
        feature.type = .polygon
        feature.geometry = [
            command(id: 1, count: 1),
            parameter(0),
            parameter(0),
            command(id: 2, count: 3),
            parameter(Int32(extent)),
            parameter(0),
            parameter(0),
            parameter(Int32(extent)),
            parameter(-Int32(extent)),
            parameter(0),
            command(id: 7, count: 1)
        ]

        var layer = VectorTile_Tile.Layer()
        layer.version = 2
        layer.name = "solid"
        layer.extent = extent
        layer.features = [feature]

        var tile = VectorTile_Tile()
        tile.layers = [layer]
        return tile
    }

    private func makeComplexOceanTile() -> VectorTile_Tile {
        var geometry: [UInt32] = []
        var cursor = SIMD2<Int32>(0, 0)
        appendRing(points: [
            SIMD2(0, 0),
            SIMD2(4096, 0),
            SIMD2(4096, 4096),
            SIMD2(0, 4096)
        ], to: &geometry, cursor: &cursor)

        let holeCount = TileMvtParser.complexOceanHoleSplitThreshold + 1
        for index in 0..<holeCount {
            let column = index % 13
            let row = index / 13
            let x = Int32(128 + column * 280)
            let y = Int32(128 + row * 280)
            appendRing(points: [
                SIMD2(x, y),
                SIMD2(x, y + 64),
                SIMD2(x + 64, y + 64),
                SIMD2(x + 64, y)
            ], to: &geometry, cursor: &cursor)
        }

        var feature = VectorTile_Tile.Feature()
        feature.id = 1
        feature.type = .polygon
        feature.geometry = geometry

        var layer = VectorTile_Tile.Layer()
        layer.version = 2
        layer.name = "ocean"
        layer.extent = 4096
        layer.features = [feature]

        var tile = VectorTile_Tile()
        tile.layers = [layer]
        return tile
    }

    private func appendRing(points: [SIMD2<Int32>],
                            to geometry: inout [UInt32],
                            cursor: inout SIMD2<Int32>) {
        guard let first = points.first else {
            return
        }

        geometry.append(command(id: 1, count: 1))
        geometry.append(parameter(first.x - cursor.x))
        geometry.append(parameter(first.y - cursor.y))
        cursor = first

        geometry.append(command(id: 2, count: UInt32(points.count - 1)))
        for point in points.dropFirst() {
            geometry.append(parameter(point.x - cursor.x))
            geometry.append(parameter(point.y - cursor.y))
            cursor = point
        }

        geometry.append(command(id: 7, count: 1))
    }

    private func parseFallbackWaterLabels(
        language: ImmersiveMapSettings.LabelLanguage,
        tile: Tile = Tile(x: 0, y: 0, z: 0),
        mvtData: Data? = nil,
        glyphCoverage: VectorTileLabelGlyphCoverage = .legacyAtlasForTests,
        fallbackPolicy: ImmersiveMapSettings.LabelFallbackPolicy = .international,
        tileProvider: AnyImmersiveMapTileProvider? = nil
    ) throws -> [String] {
        var config = ImmersiveMapSettings.default
        if let tileProvider {
            config = config.tileProvider(tileProvider)
        }
        config.labels.language = language
        config.labels.fallbackPolicy = fallbackPolicy

        let parser = TileMvtParser(determineFeatureStyle: DetermineFeatureStyle(mapStyle: FallbackWaterLabelStyle()),
                                   labelProviderProfile: ImmersiveMapProviderRuntimeContext(settings: config).labelProviderProfile,
                                   config: config,
                                   glyphCoverage: glyphCoverage)
        let parsedTile = try parser.parse(tile: tile,
                                          mvtData: mvtData ?? VectorTile_Tile().serializedData())

        return parsedTile.textLabels.map(\.text)
    }

    private static func bundledGlyphCoverage() throws -> VectorTileLabelGlyphCoverage {
        let boldAtlas = try loadBundledAtlas(named: "atlas")
        let thinAtlas = try loadBundledAtlas(named: "atlas_thin")
        return VectorTileLabelGlyphCoverage(atlasData: boldAtlas, thinAtlasData: thinAtlas)
    }

    private static func loadBundledAtlas(named name: String) throws -> AtlasData {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AtlasData.self, from: data)
    }

    private func makeProviderAtlanticOceanTile(name: String = "Atlantic Ocean",
                                               englishName: String = "Atlantic Ocean") -> VectorTile_Tile {
        var feature = VectorTile_Tile.Feature()
        feature.id = 1
        feature.type = .point
        feature.tags = [
            0, 0,
            1, 1,
            2, 2,
            3, 3
        ]
        feature.geometry = [
            command(id: 1, count: 1),
            parameter(2048),
            parameter(2048)
        ]

        var layer = VectorTile_Tile.Layer()
        layer.version = 2
        layer.name = "natural_label"
        layer.extent = 4096
        layer.keys = ["class", "type", "name", "name_en"]
        layer.values = [
            stringValue("ocean"),
            stringValue("ocean"),
            stringValue(name),
            stringValue(englishName)
        ]
        layer.features = [feature]

        var tile = VectorTile_Tile()
        tile.layers = [layer]
        return tile
    }

    private func command(id: UInt32, count: UInt32) -> UInt32 {
        (count << 3) | id
    }

    private func parameter(_ value: Int32) -> UInt32 {
        UInt32(bitPattern: (value << 1) ^ (value >> 31))
    }

    private func stringValue(_ value: String) -> VectorTile_Tile.Value {
        var tileValue = VectorTile_Tile.Value()
        tileValue.stringValue = value
        return tileValue
    }
}

private final class FallbackWaterLabelStyle: ImmersiveMapStyle {
    let preparedTileStyleRevision: UInt32 = 1

    private let oceanLabelTextStyle = LabelTextStyle(key: 3,
                                                     fillColor: SIMD3<Float>(0, 0, 1),
                                                     strokeColor: SIMD3<Float>(1, 1, 1),
                                                     strokeWidthPx: 1,
                                                     sizePx: 12,
                                                     weight: .bold)
    private let seaLabelTextStyle = LabelTextStyle(key: 4,
                                                   fillColor: SIMD3<Float>(0, 0, 1),
                                                   strokeColor: SIMD3<Float>(1, 1, 1),
                                                   strokeWidthPx: 1,
                                                   sizePx: 10,
                                                   weight: .thin)

    func getMapBaseColors() -> ImmersiveMapBaseColors {
        ImmersiveMapBaseColors()
    }

    func makeStyle(data: DetFeatureStyleData) -> FeatureStyle {
        let labelTextStyle: LabelTextStyle?
        switch data.properties["class"]?.stringValue {
        case "ocean":
            labelTextStyle = oceanLabelTextStyle
        case "sea":
            labelTextStyle = seaLabelTextStyle
        default:
            labelTextStyle = nil
        }

        return FeatureStyle(key: UInt8(labelTextStyle?.key ?? 0),
                            color: SIMD4<Float>(1, 1, 1, 1),
                            parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 1),
                            labelTextStyle: labelTextStyle)
    }
}

private final class ParserSolidPolygonStyle: ImmersiveMapStyle {
    let preparedTileStyleRevision: UInt32 = 1

    func getMapBaseColors() -> ImmersiveMapBaseColors {
        ImmersiveMapBaseColors()
    }

    func makeStyle(data: DetFeatureStyleData) -> FeatureStyle {
        let key: UInt8 = data.layerName == "background" ? 1 : 2
        return FeatureStyle(key: key,
                     color: SIMD4<Float>(1, 1, 1, 1),
                     parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 1))
    }
}

private struct ParserProviderIDTestTileProvider: ImmersiveMapTileProvider {
    let id: String

    var cacheNamespace: String {
        id
    }

    var configurationFingerprint: UInt64 {
        1
    }

    var tileSource: ImmersiveMapTileSource {
        .url(URL(string: "https://example.com/api/v1/map/tiles")!)
    }

    var maximumTileZoomLevel: Int? {
        nil
    }
}

extension ParserProviderIDTestTileProvider: ImmersiveMapTileProviderRuntime {
    func makeLabelProviderProfile(settings: ImmersiveMapSettings) -> any VectorTileLabelProviderProfile {
        ParserProviderIDTestLabelProviderProfile(providerID: id)
    }
}

private struct ParserProviderIDTestLabelProviderProfile: VectorTileLabelProviderProfile {
    let providerID: String

    var languagePreferences: VectorTileLabelLanguagePreferences {
        .from(settingsLanguage: .english, fallbackPolicy: .international)
    }

    func sortKey(properties: [String: VectorTile_Tile.Value]) -> Int {
        0
    }

    func collisionRank(layerName: String, sortKey: Int) -> Int {
        sortKey
    }

    func includesBasePointLabel(layerName: String,
                                properties: [String: VectorTile_Tile.Value],
                                tileZoom: Int,
                                sortKey: Int) -> Bool {
        true
    }

    func identity(feature: VectorTileLabelFeature, text: String, kind: String) -> VectorTileLabelIdentity {
        .providerFeature(providerID: feature.providerID,
                         layerName: feature.layerName,
                         featureID: feature.featureID ?? 0)
    }

    func normalizedKind(layerName: String, properties: [String: VectorTile_Tile.Value]) -> String {
        layerName
    }

    func isHouseNumberLayer(_ layerName: String) -> Bool {
        false
    }
}
