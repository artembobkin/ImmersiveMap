// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The label switch (`LabelSettings.isEnabled`) at parse time: off, the
/// parser bakes no text label and no road label into the tile. The flag is
/// prepared-cache identity, pinned alongside.
final class LabelsEnabledParseTests: XCTestCase {
    private static let tile = Tile(x: 9908, y: 5140, z: 14)

    private func makeParser(labelsEnabled: Bool) -> TileMvtParser {
        var config = ImmersiveMapSettings.default
        config.labels.isEnabled = labelsEnabled
        return TileMvtParser(
            determineFeatureStyle: DetermineFeatureStyle(mapStyle: ImmersiveMapTilesDefaultMapStyle()),
            labelProviderProfile: ImmersiveMapProviderRuntimeContext(settings: config).labelProviderProfile,
            config: config,
            glyphCoverage: .legacyAtlasForTests
        )
    }

    /// A named peak and a named primary road: one point label, one road label.
    private func parseNamedTile(labelsEnabled: Bool) throws -> TileMvtParser.ParsedTile {
        let data = VectorTileFixture.layersTile([
            (layerName: "mountain_peak",
             features: [.init(id: 1, geometry: .point(2048, 2048), properties: ["name": "Peak", "rank": "1"])]),
            (layerName: "transportation_name",
             features: [.init(id: 2,
                              geometry: .line(points: [(256, 2048), (3840, 2048)]),
                              properties: ["class": "primary", "name": "Main Street"])])
        ])
        return try makeParser(labelsEnabled: labelsEnabled).parse(tile: Self.tile, mvtData: data)
    }

    func testLabelsOffBakesNoText() throws {
        let labelled = try parseNamedTile(labelsEnabled: true)
        XCTAssertFalse(labelled.textLabels.isEmpty, "Labels on bake the peak's name")
        XCTAssertFalse(labelled.roadTextLabels.isEmpty, "Labels on bake the road's name")

        let unlabelled = try parseNamedTile(labelsEnabled: false)
        XCTAssertTrue(unlabelled.textLabels.isEmpty, "Labels off bake no point label")
        XCTAssertTrue(unlabelled.roadTextLabels.isEmpty, "Labels off bake no road label")
    }

    func testTheSwitchIsPreparedCacheIdentity() {
        func namespace(labelsEnabled: Bool) -> String {
            PreparedTileCacheIdentity(preparedFormatVersion: 88,
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
                                      roofShapesEnabled: false,
                                      buildingExtrusionEnabled: true,
                                      labelsEnabled: labelsEnabled).namespaceComponent
        }
        XCTAssertNotEqual(namespace(labelsEnabled: true), namespace(labelsEnabled: false),
                          "A tile prepared without labels must not answer a map that wants them")
    }

    func testLabelsAreOnByDefault() {
        XCTAssertTrue(ImmersiveMapSettings.default.labels.isEnabled)
    }
}
