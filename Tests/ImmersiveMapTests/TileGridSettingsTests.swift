// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The tile grid's public settings: the defaults, the modifiers on the
/// settings value and on the view, and how a change is applied.
@MainActor
final class TileGridSettingsTests: XCTestCase {
    func testTheDefaults() {
        let grid = ImmersiveMapSettings.TileGridSettings()
        XCTAssertEqual(grid.zoomRange, 0 ... ImmersiveMapTileID.maximumZoom)
        XCTAssertEqual(grid.labelFormat, .zxy)
        XCTAssertTrue(grid.isTapSelectionEnabled)
        XCTAssertNil(grid.selectionLimit)
        XCTAssertNil(grid.selectableBounds)
        XCTAssertEqual(grid.selectionGesture, .tap)
        XCTAssertEqual(grid.selectionMode, .multiple)
        let picked = ImmersiveMapSettings.default.tileGridSettings(selectionGesture: .doubleTap, selectionMode: .single)
        XCTAssertEqual(picked.tileGrid.selectionGesture, .doubleTap)
        XCTAssertEqual(picked.tileGrid.selectionMode, .single)
        XCTAssertEqual(picked.tileGridSettings(lineWidthPoints: 2).tileGrid.selectionGesture, .doubleTap)
        XCTAssertEqual(ImmersiveMapSettings.default.tileGrid, grid)
    }

    func testAnOmittedValueIsLeftAsConfigured() {
        let settings = ImmersiveMapSettings.default
            .tileGridSettings(zoomRange: 12 ... 15, lineWidthPoints: 2)
            .tileGridSettings(labelFormat: .xyz)
        XCTAssertEqual(settings.tileGrid.zoomRange, 12 ... 15)
        XCTAssertEqual(settings.tileGrid.lineWidthPoints, 2)
        XCTAssertEqual(settings.tileGrid.labelFormat, .xyz)
        XCTAssertEqual(settings.tileGrid.labelColor, ImmersiveMapSettings.TileGridSettings().labelColor)

        XCTAssertEqual(ImmersiveMapSettings.default.tileGridSettings(zoomRange: -4 ... 99).tileGrid.zoomRange,
                       0 ... ImmersiveMapTileID.maximumZoom, "A range is kept within the zooms a tile is named at")
        XCTAssertEqual(ImmersiveMapSettings.default.tileGridSettings(lineWidthPoints: -1).tileGrid.lineWidthPoints, 0)
    }

    func testTheSelectionRulesAreSetAsGiven() {
        let city = ImmersiveMapGeoBounds(southWest: GeoCoordinate(latitude: 40.5, longitude: -74.3),
                                         northEast: GeoCoordinate(latitude: 40.9, longitude: -73.7))
        let limited = ImmersiveMapSettings.default.tileGridSelection(limit: 20, selectableBounds: city)
        XCTAssertEqual(limited.tileGrid.selectionLimit, 20)
        XCTAssertEqual(limited.tileGrid.selectableBounds, city)
        let free = limited.tileGridSelection(limit: nil, selectableBounds: nil)
        XCTAssertNil(free.tileGrid.selectionLimit, "Nil is a value here: no limit")
        XCTAssertNil(free.tileGrid.selectableBounds)
    }

    func testTheViewsModifiersWriteThrough() {
        let custom = ImmersiveMapSettings.TileGridSettings(zoomRange: 15 ... 15, selectionLimit: 3)
        XCTAssertEqual(ImmersiveMapView().tileGridSettings(custom).settings.tileGrid, custom)
        XCTAssertEqual(ImmersiveMapView().tileGridSettings(zoomRange: 14 ... 14).settings.tileGrid.zoomRange, 14 ... 14)
        XCTAssertEqual(ImmersiveMapView().tileGridSelection(limit: 5, selectableBounds: nil).settings.tileGrid.selectionLimit,
                       5)
    }

    func testAChangeIsAppliedInPlace() {
        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(
            from: .default,
            to: ImmersiveMapSettings.default.tileGridSettings(zoomRange: 15 ... 15))
        XCTAssertEqual(plan.changedDomains, [.tileGrid])
        XCTAssertEqual(plan.actions, [.liveApply])
        XCTAssertFalse(plan.requiresRendererRecreation)
    }
}
