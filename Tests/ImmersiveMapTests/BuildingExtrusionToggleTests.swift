// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The theme's extrusion switch (`ImmersiveMapTilesTheme.features.buildingExtrusion`):
/// off, the built-in style answers a flat fill for every building, the
/// parser raises nothing and the footprint stays a ground fill. The switch
/// is part of the theme, so it is prepared-cache identity and a heavy
/// settings change like any other theme change.
@MainActor
final class BuildingExtrusionToggleTests: XCTestCase {
    private static let tile = Tile(x: 9908, y: 5140, z: 14)

    private static func theme(extrusion: Bool) -> ImmersiveMapTilesTheme {
        ImmersiveMapTilesTheme.default.apply { theme in
            theme.features.buildingExtrusion = extrusion
        }
    }

    private func makeParser(extrusion: Bool) -> TileMvtParser {
        TileMvtParser.forTests(settings: .default,
                               mapStyle: ImmersiveMapTilesDefaultMapStyle(theme: Self.theme(extrusion: extrusion)))
    }

    private func parseBuildingTile(extrusion: Bool) throws -> ParsedTile {
        let data = VectorTileFixture.layerTile(
            layerName: "building",
            features: [
                .init(id: 1,
                      geometry: .polygon(ring: [(1024, 1024), (2048, 1024), (2048, 2048), (1024, 2048)]),
                      properties: ["render_height": "40"])
            ])
        return try makeParser(extrusion: extrusion).parse(tile: Self.tile, mvtData: data)
    }

    func testDisabledExtrusionLeavesTheFlatFootprintFill() throws {
        let raised = try parseBuildingTile(extrusion: true)
        XCTAssertGreaterThan(raised.drawingExtruded.indices.count, 0,
                             "Enabled extrusion raises the building")
        let flat = try parseBuildingTile(extrusion: false)
        XCTAssertEqual(flat.drawingExtruded.indices.count, 0,
                       "Disabled extrusion raises no building")
        XCTAssertGreaterThan(flat.drawingPolygon.indices.count, 0,
                             "The footprint stays a flat ground fill")
        XCTAssertEqual(flat.drawingPolygon.indices.count, raised.drawingPolygon.indices.count,
                       "The ground fill is the same with or without the extrusion")
    }

    func testTheSwitchIsPartOfTheThemeFingerprint() {
        XCTAssertNotEqual(Self.theme(extrusion: true).cacheFingerprint,
                          Self.theme(extrusion: false).cacheFingerprint,
                          "A tile prepared flat must not answer a map that wants its buildings raised")
    }

    func testExtrusionIsOnByDefault() {
        XCTAssertTrue(ImmersiveMapTilesTheme.default.features.buildingExtrusion, "Buildings rise unless asked not to")
    }

    func testTogglingTheSwitchIsAHeavySettingsChange() {
        let old = ImmersiveMapSettings.default
        let new = old.mapStyle(ImmersiveMapTilesMapStyle(theme: Self.theme(extrusion: false)))
        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: old, to: new)
        XCTAssertTrue(plan.actions.contains(.rebuildPreparedData),
                      "Extrusions are baked at parse time: the prepared tiles must rebuild")
        XCTAssertTrue(plan.actions.contains(.invalidateCaches))
        XCTAssertTrue(plan.requiresRendererRecreation)
    }
}
