// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The map of a night out of the box: the night palette, the night's air
/// and the one modifier that sets both.
final class NightThemeTests: XCTestCase {
    /// The night is its own palette, baked into its own tiles: a dark land
    /// and water, near-white labels, the globe's biomes sunk into the dark,
    /// with the day's metrics and visibility.
    func testTheNightPaletteIsDarkAndItsOwnCacheIdentity() {
        let day = ProtomapsBasemapTheme.default
        let night = ProtomapsBasemapTheme.night

        XCTAssertNotEqual(night.cacheFingerprint, day.cacheFingerprint)
        XCTAssertLessThan(night.layers.land.x + night.layers.land.y + night.layers.land.z, 0.5)
        XCTAssertLessThan(night.layers.water.y, day.layers.water.y)
        XCTAssertGreaterThan(night.labels.city.fillColor.x, 0.9, "Labels are near-white on the dark")
        XCTAssertLessThan(night.labels.city.strokeColor.x, 0.1)
        XCTAssertLessThan(night.layers.biomes.temperateBroadleafForest.y, day.layers.biomes.temperateBroadleafForest.y * 0.5,
                          "The biomes sink into the night")
        let forest = night.layers.biomes.temperateBroadleafForest
        let desert = night.layers.biomes.desert
        XCTAssertGreaterThan(forest.y - forest.x, desert.y - desert.x, "A forest stays a greener dark than a desert")
        XCTAssertEqual(night.roadMetrics, day.roadMetrics, "The night changes colours, not the road metrics")
        XCTAssertEqual(night.labelVisibility, day.labelVisibility)
        XCTAssertEqual(night.baseColors.map, night.layers.land, "What no tile paints follows the night's land")
    }

    /// One modifier sets the palette and the air, and takes both back.
    func testTheNightModifierSetsThePaletteAndTheAir() {
        let night = ImmersiveMapSettings.default.night()
        XCTAssertEqual(night.mapStyle, AnyImmersiveMapMapStyle(ProtomapsBasemapMapStyle.night))
        XCTAssertEqual(night.mapStyle.basemapTheme, ProtomapsBasemapTheme.night)
        XCTAssertEqual(night.scene.fog, .night)
        XCTAssertNil(night.scene.groundFog.color, "The ground fog follows the night's horizon")
        XCTAssertLessThan(night.scene.fog.skyColor.z, 0.2, "A navy sky")

        let day = night.night(false)
        XCTAssertEqual(day.mapStyle, ImmersiveMapSettings.default.mapStyle)
        XCTAssertEqual(day.scene.fog, ImmersiveMapSettings.FogSettings())
    }

    /// The change of palette re-prepares the tiles, as any change of style,
    /// and the air applies live with it.
    func testTheNightIsAStyleChangeForThePlanner() {
        let day = ImmersiveMapSettings.default
        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: day, to: day.night())

        XCTAssertTrue(plan.changedDomains.contains(.style))
        XCTAssertTrue(plan.actions.contains(.rebuildPreparedData))
    }

    /// The style reads as `.night` without its type name, like `.default`.
    @MainActor
    func testTheNightStyleSpellsWithoutItsTypeName() {
        let view = ImmersiveMapView().mapStyle(.night)
        XCTAssertEqual(view.settings.mapStyle, AnyImmersiveMapMapStyle(ProtomapsBasemapMapStyle.night))
    }
}
