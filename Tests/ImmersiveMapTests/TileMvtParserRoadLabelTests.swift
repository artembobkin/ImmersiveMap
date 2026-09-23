// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
#if canImport(MvtTestSupport)
import MvtTestSupport
#endif
import XCTest

final class TileMvtParserRoadLabelTests: XCTestCase {
    func testRoadLabelsUseSharedResolverLanguagePreferences() throws {
        var config = ImmersiveMapSettings.default
        config.labels.language = .french

        let parser = TileMvtParser.forTests(settings: config,
                                            mapStyle: RoadLabelStyle())
        let parsedTile = try parser.parse(tile: Tile(x: 0, y: 0, z: 14),
                                          mvtData: makeRoadLabelTile().serializedData())

        XCTAssertEqual(parsedTile.roadTextLabels.map(\.text), ["Rue de Rivoli"])
    }

    private func makeRoadLabelTile() -> MvtTileMessage {
        var feature = MvtFeatureMessage()
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

        var layer = MvtLayerMessage()
        layer.version = 2
        layer.name = "roads"
        layer.extent = 4096
        layer.keys = ["name", "name:en", "name:fr"]
        layer.values = [
            stringValue("Rue Native"),
            stringValue("Rivoli Street"),
            stringValue("Rue de Rivoli")
        ]
        layer.features = [feature]

        var tile = MvtTileMessage()
        tile.layers = [layer]
        return tile
    }

    private func command(id: UInt32, count: UInt32) -> UInt32 {
        (count << 3) | id
    }

    private func parameter(_ value: Int32) -> UInt32 {
        UInt32(bitPattern: (value << 1) ^ (value >> 31))
    }

    private func stringValue(_ value: String) -> MvtValue {
        .string(value)
    }
}

private struct RoadLabelStyle: ImmersiveMapVectorTileStyle {
    let cacheFingerprint: UInt32 = 1

    private let roadLabelTextStyle = LabelTextStyle(key: 1,
                                                    fillColor: SIMD3<Float>(1, 1, 1),
                                                    strokeColor: SIMD3<Float>(0, 0, 0),
                                                    haloEm: 0.1,
                                                    sizePoints: 12,
                                                    weight: .thin)

    func makeStyle(for feature: ImmersiveMapFeatureStyleContext) -> FeatureStyle {
        .road(RoadStyle(fill: LinePass(key: 1,
                                       color: SIMD4<Float>(1, 1, 1, 1),
                                       lineGeometry: LineGeometryStyle(lineWidth: 8)),
                        label: roadLabelTextStyle))
    }

    func backgroundStyle(tileZoom: Int) -> FeatureStyle {
        .fill(FillStyle(key: 1, color: SIMD4<Float>(1, 1, 1, 1)))
    }
}
