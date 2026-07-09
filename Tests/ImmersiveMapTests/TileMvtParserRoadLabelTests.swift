// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class TileMvtParserRoadLabelTests: XCTestCase {
    func testRoadLabelsUseSharedResolverLanguagePreferences() throws {
        var config = ImmersiveMapSettings.default
        config.labels.language = .french

        let parser = TileMvtParser(determineFeatureStyle: DetermineFeatureStyle(mapStyle: RoadLabelStyle()),
                                   labelProviderProfile: ImmersiveMapProviderRuntimeContext(settings: config).labelProviderProfile,
                                   config: config,
                                   glyphCoverage: .legacyAtlasForTests)
        let parsedTile = try parser.parse(tile: Tile(x: 0, y: 0, z: 14),
                                          mvtData: try makeRoadLabelTile().serializedData())

        XCTAssertEqual(parsedTile.roadTextLabels.map(\.text), ["Rue de Rivoli"])
    }

    private func makeRoadLabelTile() -> VectorTile_Tile {
        var feature = VectorTile_Tile.Feature()
        feature.id = 1
        feature.type = .linestring
        feature.tags = [
            0, 0,
            1, 1,
            2, 2
        ]
        feature.geometry = [
            command(id: 1, count: 1),
            parameter(100),
            parameter(100),
            command(id: 2, count: 1),
            parameter(800),
            parameter(0)
        ]

        var layer = VectorTile_Tile.Layer()
        layer.version = 2
        layer.name = "road"
        layer.extent = 4096
        layer.keys = ["name", "name_en", "name_fr"]
        layer.values = [
            stringValue("Rue Native"),
            stringValue("Rivoli Street"),
            stringValue("Rue de Rivoli")
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

private final class RoadLabelStyle: ImmersiveMapStyle {
    let preparedTileStyleRevision: UInt32 = 1

    private let roadLabelTextStyle = LabelTextStyle(key: 1,
                                                    fillColor: SIMD3<Float>(1, 1, 1),
                                                    strokeColor: SIMD3<Float>(0, 0, 0),
                                                    strokeWidthPx: 1,
                                                    sizePx: 12,
                                                    weight: .thin)

    func getMapBaseColors() -> ImmersiveMapBaseColors {
        ImmersiveMapBaseColors()
    }

    func makeStyle(data: DetFeatureStyleData) -> FeatureStyle {
        FeatureStyle(key: 1,
                     color: SIMD4<Float>(1, 1, 1, 1),
                     parseGeometryStyleData: TileMvtParser.ParseGeometryStyleData(lineWidth: 8),
                     includeRoadLabelPath: true,
                     roadLabelTextStyle: roadLabelTextStyle)
    }
}
