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

    /// The night is the map's, not the planet's: the globe wears the day's
    /// palette, its caps included, and the palette is part of the tiles'
    /// identity.
    func testTheGlobeOfTheNightIsTheDays() {
        let day = ProtomapsBasemapTheme.default
        let night = ProtomapsBasemapTheme.night

        XCTAssertEqual(night.globeLayers, day.layers)
        XCTAssertEqual(night.globeLabels, day.labels, "The globe's names are the day's lettering")
        XCTAssertNil(day.globeLayers, "The day's globe is the day's own palette")
        XCTAssertNil(day.globeLabels)
        let planetLetteredByNight = night.apply { $0.globeLabels = nil }
        XCTAssertNotEqual(planetLetteredByNight.cacheFingerprint, night.cacheFingerprint,
                          "The globe's labels are baked into the tiles")
        let ownLettering = day.globeLabels { $0.country.fillColor = SIMD3<Float>(1, 0, 1) }
        XCTAssertEqual(ownLettering.globeLabels?.country.fillColor, SIMD3<Float>(1, 0, 1))
        XCTAssertEqual(ownLettering.globeLabels?.city, day.labels.city, "The builder starts from the plane's labels")
        XCTAssertEqual(night.baseColors.northCap, day.layers.water, "The caps are the globe's")
        XCTAssertEqual(night.baseColors.southCap, day.layers.ice)
        let planetOfTheNight = night.apply { $0.globeLayers = nil }
        XCTAssertNotEqual(planetOfTheNight.cacheFingerprint, night.cacheFingerprint,
                          "The globe's palette is baked into the tiles")
        let ownGlobe = day.globeLayers { $0.water = SIMD4<Float>(1, 0, 1, 1) }
        XCTAssertEqual(ownGlobe.globeLayers?.water, SIMD4<Float>(1, 0, 1, 1))
        XCTAssertEqual(ownGlobe.globeLayers?.land, day.layers.land, "The builder starts from the plane's palette")
    }

    /// Every fill and stroke of the overview zooms states the day's colour
    /// as what it wears on the globe, under the night's own for the plane,
    /// and a theme without a globe palette states none.
    func testTheNightsGroundWearsTheDaysColoursOnTheGlobe() throws {
        let day = ProtomapsBasemapTheme.default
        let night = ProtomapsBasemapDefaultMapStyle(theme: .night)
        func fill(_ style: FeatureStyle) throws -> FillStyle {
            guard case .fill(let fill) = style else { throw XCTSkip("not a fill") }
            return fill
        }
        func line(_ style: FeatureStyle) throws -> LinePass {
            guard case .line(let line) = style else { throw XCTSkip("not a line") }
            return line.pass
        }
        func rgb(_ color: SIMD4<Float>) -> SIMD3<Float> { SIMD3<Float>(color.x, color.y, color.z) }

        let forest = try fill(night.biomeStyle(kind: "temperate_broadleaf_forest", tileZoom: 3))
        XCTAssertEqual(forest.color, ProtomapsBasemapTheme.night.layers.biomes.temperateBroadleafForest)
        XCTAssertEqual(forest.sphereColor, rgb(day.layers.biomes.temperateBroadleafForest))
        let lake = try fill(night.overviewLakeStyle(tileZoom: 0))
        XCTAssertEqual(lake.sphereColor, rgb(day.layers.water))
        let ocean = try fill(night.makeStyle(data: DetFeatureStyleData(layerName: "water", properties: [:],
                                                                       tile: Tile(x: 0, y: 0, z: 2))))
        XCTAssertEqual(ocean.color, ProtomapsBasemapTheme.night.layers.water)
        XCTAssertEqual(ocean.sphereColor, rgb(day.layers.water))
        let earth = try fill(night.makeStyle(data: DetFeatureStyleData(layerName: "earth", properties: [:],
                                                                       tile: Tile(x: 0, y: 0, z: 2))))
        XCTAssertEqual(earth.sphereColor, rgb(day.layers.land))
        let cover = try fill(night.landcoverStyle(kind: "forest", tileZoom: 4))
        XCTAssertEqual(cover.sphereColor, rgb(day.layers.biomes.forestCover))
        let highway = try line(night.overviewRoadNetworkStyle(rank: 1, tileZoom: 3))
        XCTAssertEqual(highway.sphereColor, rgb(day.layers.overviewRoads.major))
        let border = try line(night.boundaryStyle(kind: "country", props: [:], tileZoom: 3))
        XCTAssertEqual(border.sphereColor,
                       rgb(ProtomapsBasemapDefaultMapStyle.softenedBoundaryColor(day.layers.boundary, towardWhite: 0.15, alpha: 0.55)))

        let dayStyle = ProtomapsBasemapDefaultMapStyle(theme: day)
        XCTAssertNil(try fill(dayStyle.biomeStyle(kind: "desert", tileZoom: 3)).sphereColor)
        XCTAssertNil(try fill(dayStyle.overviewLakeStyle(tileZoom: 0)).sphereColor)
        XCTAssertNil(try line(dayStyle.boundaryStyle(kind: "country", props: [:], tileZoom: 3)).sphereColor)
    }

    /// The names of the globe's zooms state the day's fill and halo as
    /// what they wear on the globe, in the night's own size and weight,
    /// and the names never on the globe, and a theme without globe labels,
    /// state none.
    func testTheNightsNamesWearTheDaysLetteringOnTheGlobe() throws {
        let day = ProtomapsBasemapTheme.default
        let night = ProtomapsBasemapDefaultMapStyle(theme: .night)
        func text(_ style: FeatureStyle) throws -> LabelTextStyle {
            guard case .pointLabel(let label) = style else { throw XCTSkip("not a label") }
            return label.text
        }

        let country = try text(night.placeLabelStyle(kind: "country", kindDetail: nil, props: [:]))
        XCTAssertEqual(country.fillColor, ProtomapsBasemapTheme.night.labels.country.fillColor)
        XCTAssertEqual(country.sphereFillColor, day.labels.country.fillColor)
        XCTAssertEqual(country.sphereStrokeColor, day.labels.country.strokeColor)
        let capital = try text(night.placeLabelStyle(kind: "locality", kindDetail: "city", props: ["capital": .string("yes")]))
        XCTAssertEqual(capital.weight, .bold, "The capital's weight is the night's own rule")
        XCTAssertEqual(capital.sphereFillColor, day.labels.city.fillColor)
        let ocean = try text(night.waterLabelStyle(kind: "ocean", props: [:], tileZoom: 0))
        XCTAssertEqual(ocean.sphereFillColor, day.labels.water.fillColor)
        let poi = try text(night.poiLabelStyle(kind: "park", props: [:]))
        XCTAssertNil(poi.sphereFillColor, "A POI is never on the globe")

        let dayCountry = try text(ProtomapsBasemapDefaultMapStyle(theme: day)
            .placeLabelStyle(kind: "country", kindDetail: nil, props: [:]))
        XCTAssertNil(dayCountry.sphereFillColor)
        XCTAssertNil(dayCountry.sphereStrokeColor)
    }

    /// The colours the drawers read: the globe's at a handover of 0, the
    /// label's own at 1 and where it states none, mixed between.
    func testALabelsColoursFollowTheHandover() {
        let lettered = LabelTextStyle(fillColor: SIMD3<Float>(1, 1, 1), strokeColor: SIMD3<Float>(0, 0, 0),
                                      haloEm: 0.1, sizePoints: 12, weight: .bold,
                                      sphereFillColor: SIMD3<Float>(0, 0, 0), sphereStrokeColor: SIMD3<Float>(1, 1, 1))
        XCTAssertEqual(lettered.fillColor(atHandover: 0), SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(lettered.strokeColor(atHandover: 0), SIMD3<Float>(1, 1, 1))
        XCTAssertEqual(lettered.fillColor(atHandover: 1), SIMD3<Float>(1, 1, 1))
        XCTAssertEqual(lettered.fillColor(atHandover: 0.25), SIMD3<Float>(0.25, 0.25, 0.25))
        XCTAssertEqual(lettered.fillColor(atHandover: 2), SIMD3<Float>(1, 1, 1), "Clamped")

        let own = LabelTextStyle(fillColor: SIMD3<Float>(1, 1, 1), strokeColor: SIMD3<Float>(0, 0, 0),
                                 haloEm: 0.1, sizePoints: 12, weight: .bold)
        XCTAssertEqual(own.fillColor(atHandover: 0), SIMD3<Float>(1, 1, 1))
        XCTAssertEqual(own.strokeColor(atHandover: 0), SIMD3<Float>(0, 0, 0))
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
