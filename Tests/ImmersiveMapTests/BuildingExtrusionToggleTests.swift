// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The extrusion toggle (`StyleSettings.buildingExtrusionEnabled`): off, the
/// parser raises no building and the footprint stays a flat ground fill. The
/// flag is prepared-cache identity and a heavy settings change.
final class BuildingExtrusionToggleTests: XCTestCase {
    private static let tile = Tile(x: 9908, y: 5140, z: 14)

    private func makeParser(extrusionEnabled: Bool) -> TileMvtParser {
        var config = ImmersiveMapSettings.default
        config.style.buildingExtrusionEnabled = extrusionEnabled
        return TileMvtParser(
            determineFeatureStyle: DetermineFeatureStyle(mapStyle: ImmersiveMapTilesDefaultMapStyle()),
            labelProviderProfile: ImmersiveMapProviderRuntimeContext(settings: config).labelProviderProfile,
            config: config,
            glyphCoverage: .legacyAtlasForTests
        )
    }

    private func parseBuildingTile(extrusionEnabled: Bool) throws -> TileMvtParser.ParsedTile {
        let data = VectorTileFixture.layerTile(
            layerName: "building",
            features: [
                .init(id: 1,
                      geometry: .polygon(ring: [(1024, 1024), (2048, 1024), (2048, 2048), (1024, 2048)]),
                      properties: ["render_height": "40"])
            ])
        return try makeParser(extrusionEnabled: extrusionEnabled).parse(tile: Self.tile, mvtData: data)
    }

    func testDisabledExtrusionLeavesTheFlatFootprintFill() throws {
        let raised = try parseBuildingTile(extrusionEnabled: true)
        XCTAssertGreaterThan(raised.drawingExtruded.indices.count, 0,
                             "Enabled extrusion raises the building")
        let flat = try parseBuildingTile(extrusionEnabled: false)
        XCTAssertEqual(flat.drawingExtruded.indices.count, 0,
                       "Disabled extrusion raises no building")
        XCTAssertGreaterThan(flat.drawingPolygon.indices.count, 0,
                             "The footprint stays a flat ground fill")
        XCTAssertEqual(flat.drawingPolygon.indices.count, raised.drawingPolygon.indices.count,
                       "The ground fill is the same with or without the extrusion")
    }

    func testTheFlagIsPreparedCacheIdentity() {
        func namespace(extrusionEnabled: Bool) -> String {
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
                                      buildingExtrusionEnabled: extrusionEnabled,
                                      labelsEnabled: true).namespaceComponent
        }
        XCTAssertNotEqual(namespace(extrusionEnabled: true), namespace(extrusionEnabled: false),
                          "A tile prepared flat must not answer a map that wants its buildings raised")
    }

    func testExtrusionIsOnByDefault() {
        XCTAssertTrue(ImmersiveMapSettings.default.style.buildingExtrusionEnabled, "Buildings rise unless asked not to")
        XCTAssertFalse(ImmersiveMapView().buildingExtrusion(isEnabled: false).settings.style.buildingExtrusionEnabled)
    }

    func testTogglingTheFlagIsAHeavySettingsChange() {
        let old = ImmersiveMapSettings.default
        var new = old
        new.style.buildingExtrusionEnabled = false
        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: old, to: new)
        XCTAssertTrue(plan.actions.contains(.rebuildPreparedData),
                      "Extrusions are baked at parse time: the prepared tiles must rebuild")
        XCTAssertTrue(plan.actions.contains(.invalidateCaches))
        XCTAssertTrue(plan.requiresRendererRecreation)
    }
}
