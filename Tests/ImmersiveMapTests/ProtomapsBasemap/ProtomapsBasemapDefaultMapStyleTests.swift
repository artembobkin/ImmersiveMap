// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import XCTest

final class ProtomapsBasemapDefaultMapStyleTests: XCTestCase {
    /// The land cover's own rules, with the overview's biomes never drawn
    /// (`themeWithoutTheOverview`).
    func testGroundStylesUseTheLayerColourAtEveryZoom() {
        let configuration = Self.themeWithoutTheOverview
        let style = ProtomapsBasemapDefaultMapStyle(theme: configuration)

        // One colour per class, at every tile zoom: the globe and the
        // street map wear the same water and the same land.
        for zoom in [2, 8, 9, 10, 12] {
            let water = makeStyle(style, layerName: "water", zoom: zoom, geometry: .polygon)
            XCTAssertEqual(water.color, configuration.layers.water, "z\(zoom)")
            let earth = makeStyle(style, layerName: "earth", kind: "earth", zoom: zoom, geometry: .polygon)
            XCTAssertEqual(earth.key, 2, "z\(zoom)")
            XCTAssertEqual(earth.color, configuration.layers.land, "z\(zoom)")
            // The base quad is the land as well, under the earth polygon.
            let background = style.backgroundStyle(tileZoom: zoom)
            XCTAssertEqual(background.key, 1, "z\(zoom)")
            XCTAssertEqual(background.color, configuration.layers.land, "z\(zoom)")
        }

        // A land cover class wears the colour of the land use kind that
        // replaces it at z8, so the swap changes geometry, not the colour.
        // At z7 the globe's vegetation blend is all but released (see
        // testMassiveOverviewMergesVegetationClassesThroughZoomTwo), so the
        // two forests agree to well under one step of an 8-bit channel.
        let coverForest = makeStyle(style, layerName: "landcover", kind: "forest", zoom: 7)
        let useForest = makeStyle(style, layerName: "landuse", kind: "forest", zoom: 8)
        XCTAssertEqual(useForest.color, configuration.layers.wood)
        let forestDifference = coverForest.color - useForest.color
        let forestStep = max(Swift.abs(forestDifference.x), Swift.abs(forestDifference.y), Swift.abs(forestDifference.z))
        XCTAssertLessThan(forestStep, 1.0 / 255.0,
                          "The z7 land cover forest must read as the z8 land use forest")

        // Cities render: the urban area class is the residential tone.
        let urban = makeStyle(style, layerName: "landcover", kind: "urban_area", zoom: 6)
        XCTAssertEqual(urban.key, 10)
        XCTAssertEqual(urban.color, configuration.layers.residential)
    }

    /// The land cover's own look on the globe, with the overview's biomes
    /// never drawn (a negative `BiomeStyles.maximumTileZoom`): the way the
    /// overview zooms draw with the overview off.
    func testMassiveOverviewMergesVegetationClassesThroughZoomTwo() {
        let configuration = Self.themeWithoutTheOverview
        let colors = configuration.layers
        let style = ProtomapsBasemapDefaultMapStyle(theme: configuration)

        for kind in ["grassland", "scrub", "farmland"] {
            XCTAssertEqual(makeStyle(style, layerName: "landcover", kind: kind, zoom: 2).color,
                           colors.grass,
                           "Expected massive overview color for \(kind)")
        }

        let overviewForest = colors.grass + (colors.wood - colors.grass) * 0.25
        XCTAssertEqual(makeStyle(style, layerName: "landcover", kind: "forest", zoom: 2).color, overviewForest)
        // Past the full merge the blend releases quickly: the merge exists
        // for the globe, and holding it into the country zooms turned a
        // farmed plain into camouflage. At z3 vegetation sits halfway toward
        // the shared tone (forests three quarters of that), and by z7 the
        // palette is nearly unmixed.
        func blended(_ base: SIMD4<Float>, amount: Float) -> SIMD4<Float> {
            base + (colors.grass - base) * amount
        }
        XCTAssertEqual(makeStyle(style, layerName: "landcover", kind: "farmland", zoom: 3).color,
                       blended(colors.farmland, amount: 0.5))
        XCTAssertEqual(makeStyle(style, layerName: "landcover", kind: "forest", zoom: 3).color,
                       blended(colors.wood, amount: 0.5 * 0.75))
        XCTAssertEqual(makeStyle(style, layerName: "landcover", kind: "forest", zoom: 7).color,
                       blended(colors.wood, amount: 0.04 * 0.75))
    }

    /// Open country has no land use counterpart: from z8 it is the bare
    /// earth polygon. So grassland and scrub leave the globe's green on the
    /// same curve as the fields and reach the land tone by z7, and the step
    /// from land cover to land use changes geometry, not colour.
    func testOpenCountryReleasesToTheLandToneByTheLastLandcoverZoom() {
        let configuration = Self.themeWithoutTheOverview
        let colors = configuration.layers
        let style = ProtomapsBasemapDefaultMapStyle(theme: configuration)
        func blended(_ base: SIMD4<Float>, amount: Float) -> SIMD4<Float> {
            base + (colors.grass - base) * amount
        }
        for kind in ["grassland", "scrub"] {
            XCTAssertEqual(makeStyle(style, layerName: "landcover", kind: kind, zoom: 3).color,
                           blended(colors.land, amount: 0.5), "\(kind) at z3")
            XCTAssertEqual(makeStyle(style, layerName: "landcover", kind: kind, zoom: 7).color,
                           blended(colors.land, amount: 0.04), "\(kind) at z7")
        }
    }

    /// With the overview's biomes never drawn (`themeWithoutTheOverview`).
    func testLandcoverAndLanduseKeepApartOnTheTilesTheyShare() {
        let configuration = Self.themeWithoutTheOverview
        let colors = configuration.layers
        let style = ProtomapsBasemapDefaultMapStyle(theme: configuration)
        // The basemap ships the continuous land cover through z7 and the
        // OSM land use from z2, so the coarse tiles carry both. One key per
        // class, and the two families never share a key.
        let cover: [(String, UInt8, SIMD4<Float>)] = [
            ("barren", 3, colors.sand),
            ("grassland", 4, colors.land + (colors.grass - colors.land) * 0.04),
            ("scrub", 4, colors.land + (colors.grass - colors.land) * 0.04),
            ("glacier", 8, colors.ice),
            ("urban_area", 10, colors.residential)
        ]
        for (kind, key, color) in cover {
            let at7 = makeStyle(style, layerName: "landcover", kind: kind, zoom: 7)
            XCTAssertEqual(at7.key, key, "Unexpected key for \(kind)")
            XCTAssertEqual(at7.color, color, "Unexpected color for \(kind)")
        }
        let use: [(String, UInt8, SIMD4<Float>)] = [
            ("residential", 9, colors.residential),
            ("industrial", 9, colors.industrial),
            ("school", 9, colors.industrial),
            ("wood", 11, colors.wood),
            ("park", 12, colors.grass),
            ("cemetery", 12, colors.grass),
            ("orchard", 13, colors.farmland),
            ("wetland", 14, colors.wetland),
            ("glacier", 17, colors.ice),
            ("beach", 18, colors.sand),
            ("runway", 19, colors.aeroway)
        ]
        for (kind, key, color) in use {
            let at8 = makeStyle(style, layerName: "landuse", kind: kind, zoom: 8)
            XCTAssertEqual(at8.key, key, "Unexpected key for \(kind)")
            XCTAssertEqual(at8.color, color, "Unexpected color for \(kind)")
            XCTAssertEqual(makeStyle(style, layerName: "landuse", kind: kind, zoom: 8).key, key,
                           "\(kind) land use draws on every tile that ships it past the overview")
        }
        XCTAssertTrue(Set(cover.map(\.1)).isDisjoint(with: Set(use.map(\.1))),
                      "Land cover and land use share the coarse tiles, so they must not share a key")
        // A protected area blankets whole city centres: a faint tint under
        // every other fill, never the park green.
        let protected = makeStyle(style, layerName: "landuse", kind: "protected_area", zoom: 12)
        XCTAssertLessThan(protected.key, 9)
        XCTAssertNotEqual(protected.color, colors.grass)
        // A kind the style does not name draws in the built tone.
        XCTAssertEqual(makeStyle(style, layerName: "landuse", kind: "brownfield", zoom: 12).key, 9)
        XCTAssertEqual(makeStyle(style, layerName: "landuse", kind: "brownfield", zoom: 12).color, colors.industrial)
    }

    /// A bridge's deck ships as a `pedestrian` area. It draws among the
    /// ground lines, over the water, the waterway lines and the ferry
    /// routes, in the land tone, on every tile that ships it.
    func testBridgeDeckDrawsAboveTheWater() {
        let style = ProtomapsBasemapDefaultMapStyle(theme: .default)
        let water = makeStyle(style, layerName: "water", kind: "water", zoom: 15, geometry: .polygon)
        let waterway = makeStyle(style, layerName: "water", kind: "river", zoom: 15, geometry: .linestring)
        let ferry = makeStyle(style, layerName: "roads", kind: "ferry", zoom: 15, geometry: .linestring)
        for kind in ["pedestrian", "pier"] {
            let deck = makeStyle(style, layerName: "landuse", kind: kind, zoom: 15)
            XCTAssertGreaterThan(deck.key, water.key, "\(kind) lies over the river")
            XCTAssertGreaterThan(deck.key, waterway.key, "\(kind) hides the river's centre line")
            XCTAssertGreaterThan(deck.key, ferry.key, "\(kind) hides the ferry routes under the bridge")
            guard case .fill(let fill) = deck else {
                return XCTFail("\(kind) is a fill")
            }
            XCTAssertTrue(fill.drawsAmongGroundLines, "\(kind) draws with the lines it covers")
            XCTAssertEqual(deck.color, style.theme.layers.land, "\(kind)")
            XCTAssertEqual(makeStyle(style, layerName: "landuse", kind: kind, zoom: 10).key, deck.key,
                           "\(kind) draws on the coarser tiles too")
        }
    }

    /// The land cover and the land use draw on every tile that ships them.
    /// The land cover, which the basemap ships through z7 only, fades out
    /// with the camera over zoom 7 to 8, where the z7 tiles still serve the
    /// view, with the overview off (`themeWithoutTheOverview`) as over the
    /// biomes. Past the overview the land use has no fade.
    func testLandcoverFadesOutOverTheLastZoomOfItsTilesAndLanduseDrawsEverywhere() {
        let style = ProtomapsBasemapDefaultMapStyle(theme: Self.themeWithoutTheOverview)
        for kind in ["barren", "grassland", "farmland", "forest", "glacier", "urban_area"] {
            for zoom in [2, 5, 7, 9] {
                let fill = makeStyle(style, layerName: "landcover", kind: kind, zoom: zoom)
                XCTAssertNotEqual(fill.key, 0, "\(kind) z\(zoom)")
                XCTAssertEqual(fill.zoomFade, .fadeOut(from: 7, to: 8), "\(kind) z\(zoom)")
            }
        }
        for kind in ["residential", "wood", "park", "farmland", "runway", "protected_area", "other", "platform"] {
            for zoom in [8, 14] {
                let fill = makeStyle(style, layerName: "landuse", kind: kind, zoom: zoom)
                XCTAssertNotEqual(fill.key, 0, "\(kind) z\(zoom)")
                XCTAssertEqual(fill.zoomFade, .none, "\(kind) z\(zoom)")
            }
        }
    }

    /// The default theme with the overview's biomes never drawn: the land
    /// cover rules as they stand with the overview off.
    private static var themeWithoutTheOverview: ProtomapsBasemapTheme {
        ProtomapsBasemapTheme.default.layers { layers in
            layers.biomes.maximumTileZoom = -1
        }
    }

    /// At the overview zooms the engine lays its biomes into the tiles and
    /// the biomes paint the land. On the globe they paint it alone, with
    /// the ice and the cities. From the cover zoom the tiles' own forests,
    /// fields, bare ground, wetlands and ice draw over them in the cover
    /// tones, under the water, the land cover fading out with the biomes
    /// over camera zoom 7 to 8 and the land use of the same ground, in its
    /// own keys over the land cover's, staying: it is what the z8 tiles
    /// carry. Past the overview the biomes and the lakes are hidden and
    /// the land use draws as on the street map.
    func testOverviewBiomesPaintTheGlobeAndTheLandCoverDrawsOverThem() {
        let configuration = ProtomapsBasemapTheme.default
        let colors = configuration.layers
        let biomes = colors.biomes
        let style = ProtomapsBasemapDefaultMapStyle(theme: configuration)
        XCTAssertEqual(biomes.maximumTileZoom, 7, "The overview paints the land through the last land cover zoom")
        XCTAssertEqual(biomes.coverMinimumTileZoom, 2, "The land cover draws over the biomes from the continent zooms")

        let painted: [(String, SIMD4<Float>)] = [
            ("tropical_moist_forest", biomes.tropicalMoistForest),
            ("tropical_dry_forest", biomes.tropicalDryForest),
            ("tropical_conifer_forest", biomes.tropicalConiferForest),
            ("temperate_broadleaf_forest", biomes.temperateBroadleafForest),
            ("temperate_conifer_forest", biomes.temperateConiferForest),
            ("boreal_forest", biomes.borealForest),
            ("tropical_grassland", biomes.tropicalGrassland),
            ("temperate_grassland", biomes.temperateGrassland),
            ("flooded_grassland", biomes.floodedGrassland),
            ("montane_grassland", biomes.montaneGrassland),
            ("tundra", biomes.tundra),
            ("mediterranean_scrub", biomes.mediterraneanScrub),
            ("desert", biomes.desert),
            ("mangrove", biomes.mangrove)
        ]
        for zoom in [0, 1, 2, 3, 5, 7] {
            let earth = makeStyle(style, layerName: "earth", kind: "earth", zoom: zoom, geometry: .polygon)
            let water = makeStyle(style, layerName: "water", zoom: zoom, geometry: .polygon)
            let ice = makeStyle(style, layerName: "landcover", kind: "glacier", zoom: zoom)
            let city = makeStyle(style, layerName: "landcover", kind: "urban_area", zoom: zoom)
            var keys: Set<UInt8> = []
            for (kind, color) in painted {
                let biome = makeStyle(style, layerName: "biome", kind: kind, zoom: zoom)
                XCTAssertEqual(biome.color, color, "\(kind) z\(zoom)")
                XCTAssertEqual(biome.zoomFade, .fadeOut(from: 7, to: 8), "\(kind) leaves with the land cover at z\(zoom)")
                XCTAssertGreaterThan(biome.key, earth.key, "\(kind) lies over the earth at z\(zoom)")
                XCTAssertLessThan(biome.key, ice.key, "\(kind) lies under the ice at z\(zoom)")
                XCTAssertLessThan(biome.key, city.key, "\(kind) lies under the cities at z\(zoom)")
                XCTAssertLessThan(biome.key, water.key, "\(kind) lies under the water at z\(zoom)")
                keys.insert(biome.key)
            }
            XCTAssertEqual(keys.count, painted.count, "One key per biome at z\(zoom)")
            // A kind the style does not name draws in the temperate grassland tone.
            XCTAssertEqual(makeStyle(style, layerName: "biome", kind: "moon", zoom: zoom).color, biomes.temperateGrassland)
            XCTAssertEqual(ice.color, colors.ice, "z\(zoom)")
            XCTAssertEqual(ice.zoomFade, .fadeOut(from: 7, to: 8), "The land cover's ice leaves with the biomes at z\(zoom)")
            let useIce = makeStyle(style, layerName: "landuse", kind: "glacier", zoom: zoom)
            XCTAssertEqual(useIce.color, colors.ice, "z\(zoom)")
            XCTAssertEqual(useIce.zoomFade, .none, "The land use's ice stays at z\(zoom)")
            XCTAssertGreaterThan(useIce.key, city.key, "The land use lies over the land cover at z\(zoom)")
            XCTAssertLessThan(useIce.key, water.key, "The land use lies under the water at z\(zoom)")
            XCTAssertEqual(city.color, colors.residential, "z\(zoom)")
            // Open country is the biome: grassland and scrub never draw,
            // and neither do the meadows of the land use.
            for kind in ["grassland", "scrub"] {
                XCTAssertEqual(makeStyle(style, layerName: "landcover", kind: kind, zoom: zoom).key, 0, "\(kind) z\(zoom)")
            }
            for kind in ["grassland", "meadow"] {
                XCTAssertEqual(makeStyle(style, layerName: "landuse", kind: kind, zoom: zoom).key, 0, "\(kind) z\(zoom)")
            }
            // The parks, the reserves and the built ground stay off the painting.
            for kind in ["national_park", "nature_reserve", "park", "military", "residential", "industrial", "protected_area"] {
                XCTAssertEqual(makeStyle(style, layerName: "landuse", kind: kind, zoom: zoom).key, 0, "\(kind) z\(zoom)")
            }
            // The overview's lakes are the water.
            let lake = makeStyle(style, layerName: "lake", kind: "lake", zoom: zoom, geometry: .polygon)
            XCTAssertEqual(lake.key, water.key, "z\(zoom)")
            XCTAssertEqual(lake.color, colors.water, "z\(zoom)")

            let cover: [(String, SIMD4<Float>, [String])] = [
                ("forest", biomes.forestCover, ["forest", "wood"]),
                ("farmland", biomes.farmlandCover, ["farmland", "orchard", "vineyard"]),
                ("barren", biomes.barrenCover, ["sand", "beach", "bare_rock", "scree"])
            ]
            if zoom < biomes.coverMinimumTileZoom {
                // The globe: the biomes alone.
                for (kind, _, useKinds) in cover {
                    XCTAssertEqual(makeStyle(style, layerName: "landcover", kind: kind, zoom: zoom).key, 0, "\(kind) z\(zoom)")
                    for useKind in useKinds {
                        XCTAssertEqual(makeStyle(style, layerName: "landuse", kind: useKind, zoom: zoom).key, 0, "\(useKind) z\(zoom)")
                    }
                }
                XCTAssertEqual(makeStyle(style, layerName: "landuse", kind: "wetland", zoom: zoom).key, 0, "wetland z\(zoom)")
            } else {
                // The country zooms: the cover over every biome, under the
                // water, the land cover fading with the biomes and the land
                // use over it, staying.
                for (kind, color, useKinds) in cover {
                    let fill = makeStyle(style, layerName: "landcover", kind: kind, zoom: zoom)
                    XCTAssertEqual(fill.color, color, "\(kind) z\(zoom)")
                    XCTAssertEqual(fill.zoomFade, .fadeOut(from: 7, to: 8), "\(kind) z\(zoom)")
                    XCTAssertGreaterThan(fill.key, keys.max() ?? 0, "\(kind) lies over the biomes at z\(zoom)")
                    XCTAssertLessThan(fill.key, city.key, "\(kind) lies under the cities at z\(zoom)")
                    for useKind in useKinds {
                        let use = makeStyle(style, layerName: "landuse", kind: useKind, zoom: zoom)
                        XCTAssertGreaterThan(use.key, city.key, "\(useKind) lies over the land cover at z\(zoom)")
                        XCTAssertLessThan(use.key, water.key, "\(useKind) lies under the water at z\(zoom)")
                        XCTAssertEqual(use.color, color, "\(useKind) wears the \(kind) cover's tone at z\(zoom)")
                        XCTAssertEqual(use.zoomFade, .none, "\(useKind) stays while the cover leaves at z\(zoom)")
                    }
                }
                let wetland = makeStyle(style, layerName: "landuse", kind: "wetland", zoom: zoom)
                XCTAssertEqual(wetland.color, colors.wetland, "z\(zoom)")
                XCTAssertEqual(wetland.zoomFade, .none, "z\(zoom)")
                XCTAssertGreaterThan(wetland.key, city.key, "The wetlands lie over the land cover at z\(zoom)")
                XCTAssertLessThan(wetland.key, useIce.key, "The ice lies over the wetlands at z\(zoom)")
            }
        }

        // Past the overview the biomes and the lakes are hidden and the land
        // use draws as on the street map.
        for (kind, _) in painted {
            XCTAssertEqual(makeStyle(style, layerName: "biome", kind: kind, zoom: 8).key, 0, "\(kind) at z8")
        }
        XCTAssertEqual(makeStyle(style, layerName: "lake", kind: "lake", zoom: 8, geometry: .polygon).key, 0)
        XCTAssertEqual(makeStyle(style, layerName: "landuse", kind: "wood", zoom: 8).key, 11)
        XCTAssertEqual(makeStyle(style, layerName: "landuse", kind: "wood", zoom: 8).color, colors.wood)
        XCTAssertEqual(makeStyle(style, layerName: "landuse", kind: "park", zoom: 8).key, 12)

        // The zooms are the theme's.
        let shorter = ProtomapsBasemapDefaultMapStyle(theme: configuration.layers { $0.biomes.maximumTileZoom = 4 })
        XCTAssertEqual(makeStyle(shorter, layerName: "biome", kind: "desert", zoom: 5).key, 0)
        XCTAssertNotEqual(makeStyle(shorter, layerName: "landcover", kind: "grassland", zoom: 5).key, 0,
                          "Past a shorter overview the land cover draws whole again")
        let later = ProtomapsBasemapDefaultMapStyle(theme: configuration.layers { $0.biomes.coverMinimumTileZoom = 5 })
        XCTAssertEqual(makeStyle(later, layerName: "landcover", kind: "forest", zoom: 4).key, 0)
        XCTAssertNotEqual(makeStyle(later, layerName: "landcover", kind: "forest", zoom: 5).key, 0)
    }

    func testEveryRoadDrawsFromTheFirstTileThatShipsIt() {
        let style = ProtomapsBasemapDefaultMapStyle(theme: .default)

        func key(_ kind: String, _ kindDetail: String?, zoom: Int) -> UInt8 {
            makeStyle(style, layerName: "roads", kind: kind, kindDetail: kindDetail, zoom: zoom).key
        }

        // The style holds no class back: the basemap's tile levels decide
        // where a road first appears. Sidewalks, crossings, the subway and
        // an aerialway draw too. Through the overview's road network zoom
        // (`OverviewRoadStyles.maximumTileZoom`) the basemap's roads give
        // way to the network, so the coarse zoom is read without the
        // overview, where the roads draw as the tiles ship them.
        let plain = ProtomapsBasemapDefaultMapStyle(theme: Self.themeWithoutTheOverview)
        for (kind, kindDetail) in [("highway", "motorway"), ("major_road", "trunk"), ("major_road", "primary"),
                                   ("ferry", nil), ("major_road", "secondary"), ("major_road", "tertiary"),
                                   ("aeroway", "runway"), ("aeroway", "apron"), ("minor_road", "residential"),
                                   ("minor_road", "service"), ("path", "footway"), ("path", "sidewalk"),
                                   ("path", "crossing"), ("rail", "subway"), ("rail", "rail"),
                                   ("aerialway", "cable_car")] as [(String, String?)] {
            for zoom in [6, 10, 12, 14, 15] {
                XCTAssertNotEqual(key(kind, kindDetail, zoom: zoom), 0, "\(kind)/\(kindDetail ?? "") z\(zoom)")
            }
            XCTAssertNotEqual(makeStyle(plain, layerName: "roads", kind: kind, kindDetail: kindDetail, zoom: 2).key, 0,
                              "\(kind)/\(kindDetail ?? "") z2 without the overview")
        }
        // A subway in its tunnel draws at the tunnel opacity.
        let subway = makeStyle(style, layerName: "roads", kind: "rail", kindDetail: "subway", zoom: 14,
                               extraProperties: ["is_tunnel": .bool(true)])
        XCTAssertLessThan(subway.color.w, ProtomapsBasemapTheme.default.layers.roads.rail.w)
        // A theme can still hold a class back.
        let heldBack = ProtomapsBasemapDefaultMapStyle(theme: .default.roadMetrics { metrics in
            metrics.minimumTileZoom.minor = 14
        })
        XCTAssertEqual(makeStyle(heldBack, layerName: "roads", kind: "minor_road", kindDetail: "residential", zoom: 13).key, 0)
    }

    func testALinkSortsOneStepUnderItsParent() {
        let style = ProtomapsBasemapDefaultMapStyle(theme: .default)
        let primary = makeStyle(style, layerName: "roads", kind: "major_road", kindDetail: "primary", zoom: 14)
        let ramp = makeStyle(style, layerName: "roads", kind: "major_road", kindDetail: "primary_link", zoom: 14,
                             extraProperties: ["is_link": .bool(true)])
        XCTAssertEqual(ramp.roadStyle?.classPriority, primary.roadStyle!.classPriority - 1)
        XCTAssertEqual(ramp.resolvedLineRenderPasses[0].color, primary.resolvedLineRenderPasses[0].color,
                       "in the parent's colour")
        XCTAssertEqual(ramp.resolvedLineRenderPasses[0].lineWidthPoints, primary.resolvedLineRenderPasses[0].lineWidthPoints,
                       "and the parent's width")
        let aisle = makeStyle(style, layerName: "roads", kind: "minor_road", kindDetail: "service", zoom: 14,
                              extraProperties: ["service": .string("parking_aisle")])
        let service = makeStyle(style, layerName: "roads", kind: "minor_road", kindDetail: "service", zoom: 14)
        XCTAssertEqual(aisle.roadStyle?.classPriority, service.roadStyle!.classPriority - 1)
    }

    func testANamedRoadCarriesItsLabelOnTheRoadPath() {
        let style = ProtomapsBasemapDefaultMapStyle(theme: .default)
        let named = makeStyle(style, layerName: "roads", kind: "major_road", kindDetail: "primary", zoom: 12,
                              extraProperties: ["name": .string("Tverskaya")])
        XCTAssertNotNil(named.roadStyle?.label, "the name is laid along the road's own symbol")
        XCTAssertEqual(named.roadStyle?.label?.key, Int(named.key))
        let overview = makeStyle(style, layerName: "roads", kind: "major_road", kindDetail: "primary", zoom: 10,
                                 extraProperties: ["name": .string("Tverskaya")])
        XCTAssertNotNil(overview.roadStyle?.label, "the overview stroke carries its name too")
        let unnamed = makeStyle(style, layerName: "roads", kind: "major_road", kindDetail: "primary", zoom: 12)
        XCTAssertNil(unnamed.roadStyle?.label)
    }

    func testAOneWayStreetCarriesArrowsInThePaintRole() {
        let style = ProtomapsBasemapDefaultMapStyle(theme: .default)
        let oneway = makeStyle(style, layerName: "roads", kind: "minor_road", kindDetail: "residential", zoom: 14,
                               extraProperties: ["oneway": .bool(true)])
        XCTAssertEqual(oneway.roadStyle?.decoration, .onewayArrow())
        let paint = oneway.resolvedLineRenderPasses.first { $0.roadPassRole == .detail }
        XCTAssertNotNil(paint, "the arrows are stamped in a paint stroke")
        XCTAssertEqual(paint?.color, ProtomapsBasemapTheme.default.layers.roads.marking)
        XCTAssertEqual(paint?.zoomFade, ImmersiveMapZoomFade.none)
        let twoWay = makeStyle(style, layerName: "roads", kind: "minor_road", kindDetail: "residential", zoom: 14)
        XCTAssertEqual(twoWay.roadStyle?.decoration, RoadDecorationKind.none)
        XCTAssertFalse(twoWay.resolvedLineRenderPasses.contains { $0.roadPassRole == .detail })
        let early = makeStyle(style, layerName: "roads", kind: "major_road", kindDetail: "primary", zoom: 13,
                              extraProperties: ["oneway": .bool(true)])
        XCTAssertEqual(early.roadStyle?.decoration, .onewayArrow(), "the arrows ride every tile that states oneway")
        let tunnel = makeStyle(style, layerName: "roads", kind: "minor_road", kindDetail: "residential", zoom: 14,
                               extraProperties: ["oneway": .bool(true), "is_tunnel": .bool(true)])
        XCTAssertEqual(tunnel.roadStyle?.decoration, RoadDecorationKind.none, "a tunnel carries no paint")
    }

    func testRoadsShowWithTheirTileWithoutAFade() {
        let style = ProtomapsBasemapDefaultMapStyle(theme: .default)
        // No road fades in with the camera: a road shows with the first
        // tile that ships it, opaque.
        for (kind, kindDetail, zoom) in [("highway", "motorway", 6), ("major_road", "trunk", 7),
                                         ("major_road", "primary", 8), ("major_road", "secondary", 9),
                                         ("major_road", "tertiary", 11), ("highway", "motorway", 12),
                                         ("minor_road", "residential", 12)] {
            let road = makeStyle(style, layerName: "roads", kind: kind, kindDetail: kindDetail, zoom: zoom)
            XCTAssertEqual(road.zoomFade, .none, kindDetail)
            for pass in road.resolvedLineRenderPasses where pass.roadPassRole != .casing {
                XCTAssertEqual(pass.zoomFade, .none, kindDetail)
            }
        }
    }

    func testAutomobileRoadsCarryNoCasingPass() {
        // The automobile tier is kerbless: the roadway is held by its fill
        // and its paint, not an outline. No drive-tier class carries a
        // casing pass at any zoom.
        let style = ProtomapsBasemapDefaultMapStyle(theme: .default)
        for (kind, kindDetail) in [("highway", "motorway"), ("major_road", "trunk"), ("major_road", "primary"),
                                   ("major_road", "secondary"), ("major_road", "tertiary"),
                                   ("minor_road", "residential"), ("minor_road", "service")] {
            for zoom in [7, 10, 12, 14, 15] {
                let roadStyle = makeStyle(style, layerName: "roads", kind: kind, kindDetail: kindDetail, zoom: zoom)
                XCTAssertFalse(roadStyle.resolvedLineRenderPasses.contains { $0.roadPassRole == .casing },
                               "\(kindDetail) at z\(zoom) must draw without a kerb")
            }
        }
    }

    /// At the overview zooms the engine lays the Natural Earth road network
    /// into the tiles, and the style draws it in place of the basemap's
    /// roads, which there are the motorways alone: the main roads by rank
    /// in the highway yellow over the minor ones, both veiled on the globe,
    /// through the network's last zoom. From the next tile zoom the
    /// basemap's roads draw as before, and a theme without the overview
    /// never hides them.
    func testOverviewRoadNetworkStandsInForTheMotorways() throws {
        let configuration = ProtomapsBasemapTheme.default
        let network = configuration.layers.overviewRoads
        let style = ProtomapsBasemapDefaultMapStyle(theme: configuration)
        XCTAssertEqual(network.maximumTileZoom, 5, "The basemap's trunks arrive at tile zoom 6")
        XCTAssertEqual(network.majorMaximumRank, 4)

        for zoom in [2, 3, 5] {
            let major = makeStyle(style, layerName: "road", zoom: zoom, geometry: .linestring,
                                  extraProperties: ["kind": .string("Road"), "rank": .int(3)])
            let minor = makeStyle(style, layerName: "road", zoom: zoom, geometry: .linestring,
                                  extraProperties: ["kind": .string("Secondary Highway"), "rank": .int(6)])
            XCTAssertEqual(major.color, network.major, "z\(zoom)")
            XCTAssertEqual(minor.color, network.minor, "z\(zoom)")
            XCTAssertEqual(major.lineWidthPoints, network.majorWidthPoints)
            XCTAssertEqual(minor.lineWidthPoints, network.minorWidthPoints)
            XCTAssertGreaterThan(major.key, minor.key, "The main roads lie over the minor ones at z\(zoom)")
            XCTAssertLessThan(major.key, makeStyle(style, layerName: "boundaries", kind: "country", zoom: zoom).key,
                              "The network lies under the borders at z\(zoom)")
            XCTAssertTrue(major.suppressPolygonFill, "A road is never a blob")
            XCTAssertTrue(major.lineGeometry.lineJoinRound)
            for pass in [major, minor] {
                XCTAssertEqual(pass.primaryPass?.sphereAlpha, configuration.roadMetrics.globeOpacity,
                               "The network wears the globe veil at z\(zoom)")
            }
            // The basemap's own motorway gives way to the network.
            XCTAssertEqual(makeStyle(style, layerName: "roads", kind: "highway", kindDetail: "motorway", zoom: zoom).key, 0,
                           "The motorway is hidden under the network at z\(zoom)")
        }
        // A rank the theme does not count as main, and a missing one, draw minor.
        XCTAssertEqual(makeStyle(style, layerName: "road", zoom: 4, geometry: .linestring,
                                 extraProperties: ["rank": .int(5)]).color, network.minor)
        XCTAssertEqual(makeStyle(style, layerName: "road", zoom: 4, geometry: .linestring).color, network.minor)
        // Past the network's zoom it is hidden and the basemap's roads draw.
        XCTAssertEqual(makeStyle(style, layerName: "road", zoom: 6, geometry: .linestring,
                                 extraProperties: ["rank": .int(3)]).key, 0)
        XCTAssertNotEqual(makeStyle(style, layerName: "roads", kind: "highway", kindDetail: "motorway", zoom: 6).key, 0)
        XCTAssertNotEqual(makeStyle(style, layerName: "roads", kind: "major_road", kindDetail: "trunk", zoom: 6).key, 0)
        // Without the overview the motorways draw where the tiles ship them.
        let plain = ProtomapsBasemapDefaultMapStyle(theme: Self.themeWithoutTheOverview)
        XCTAssertNotEqual(makeStyle(plain, layerName: "roads", kind: "highway", kindDetail: "motorway", zoom: 4).key, 0)
        XCTAssertEqual(makeStyle(plain, layerName: "road", zoom: 4, geometry: .linestring,
                                 extraProperties: ["rank": .int(3)]).key, 0)
        // The network's tones and zooms are baked into the tiles.
        let yellower = configuration.layers { $0.overviewRoads.major = SIMD4<Float>(1, 0.9, 0.2, 1) }
        XCTAssertNotEqual(yellower.cacheFingerprint, configuration.cacheFingerprint)
        let shorter = configuration.layers { $0.overviewRoads.maximumTileZoom = 4 }
        XCTAssertNotEqual(shorter.cacheFingerprint, configuration.cacheFingerprint)
        XCTAssertEqual(makeStyle(ProtomapsBasemapDefaultMapStyle(theme: shorter), layerName: "road", zoom: 5,
                                 geometry: .linestring, extraProperties: ["rank": .int(3)]).key, 0)
    }

    func testOverviewRoadsAreOneAsphaltGreyWithSeamlessJoins() throws {
        let configuration = ProtomapsBasemapTheme.default
        let style = ProtomapsBasemapDefaultMapStyle(theme: configuration)

        // Through z11 the majors draw on the country-border principle: one
        // point-locked pass, opaque past the overview band (never the
        // translucent road band), a ribbon tessellated wide enough to host
        // the stated points, and no kerb. Unlike a border the stroke has
        // round joins and caps: the tiles ship a corridor in pieces, and
        // butt ends tore it open at every bend and feature boundary.
        let motorway = makeStyle(style, layerName: "roads", kind: "highway", kindDetail: "motorway", zoom: 7)
        XCTAssertEqual(motorway.resolvedLineRenderPasses.map(\.roadPassRole), [.fill])
        let fill = motorway.resolvedLineRenderPasses[0]
        let metrics = configuration.roadMetrics
        XCTAssertEqual(fill.lineWidthPoints, metrics.symbolWidthPoints.motorway)
        let ramp = try XCTUnwrap(fill.pointWidthRamp)
        XCTAssertEqual(ramp, LinePass.WidthRamp(startWidthPoints: metrics.overviewWidthPoints.motorway,
                                                startZoom: metrics.overviewZoom,
                                                endZoom: metrics.symbolZoom,
                                                startAlpha: metrics.overviewOpacity))
        XCTAssertEqual(fill.zoomFade, .none, "Overview roads show with their tile")
        XCTAssertTrue(fill.lineGeometry.lineCapRound)
        XCTAssertTrue(fill.lineGeometry.lineJoinRound)
        XCTAssertEqual(fill.lineGeometry.lineWidth,
                       Double(ramp.widthPoints(atZoom: 8, endWidthPoints: fill.lineWidthPoints))
                           * FeatureStyle.pointLockedRibbonUnitsPerPoint,
                       accuracy: 0.01,
                       "The ribbon must host the widest the stroke gets while a z7 tile serves it")

        // The stroke is the street grey of its class, at every zoom: the
        // colour never changes on the way down.
        XCTAssertEqual(fill.color, configuration.layers.roads.motorway, "the veil is the ramp's, not the colour's")
        let primary = makeStyle(style, layerName: "roads", kind: "major_road", kindDetail: "primary", zoom: 8)
        XCTAssertEqual(primary.resolvedLineRenderPasses[0].color, configuration.layers.roads.primary)

        // The width grows with the camera, not with the tile level: every
        // tile level states the same ramp, and the ramp is monotonic.
        let cityFill = makeStyle(style, layerName: "roads", kind: "highway", kindDetail: "motorway", zoom: 10)
            .resolvedLineRenderPasses[0]
        XCTAssertEqual(cityFill.pointWidthRamp, ramp)
        XCTAssertEqual(cityFill.lineWidthPoints, fill.lineWidthPoints)
        XCTAssertEqual(ramp.widthPoints(atZoom: 5, endWidthPoints: 7), metrics.overviewWidthPoints.motorway)
        XCTAssertLessThan(ramp.widthPoints(atZoom: 8, endWidthPoints: 7), ramp.widthPoints(atZoom: 11, endWidthPoints: 7))
        XCTAssertEqual(ramp.widthPoints(atZoom: 15, endWidthPoints: 7), 7)
        for (kindDetail, zoom) in [("trunk", 6), ("secondary", 9), ("tertiary", 11)] {
            let road = makeStyle(style, layerName: "roads", kind: "major_road", kindDetail: kindDetail, zoom: zoom)
            XCTAssertGreaterThan(road.resolvedLineRenderPasses[0].lineWidthPoints, 0, "\(kindDetail) at z\(zoom)")
            XCTAssertTrue(road.resolvedLineRenderPasses[0].lineGeometry.lineJoinRound, "\(kindDetail) at z\(zoom)")
        }

        // From z12 the road stays a symbol: the class's width in points,
        // fixed on screen, with no floor because it never thins by zoom.
        let streetMotorway = makeStyle(style, layerName: "roads", kind: "highway", kindDetail: "motorway", zoom: 12)
        let streetFill = streetMotorway.resolvedLineRenderPasses.first { $0.roadPassRole == .fill }!
        XCTAssertEqual(streetFill.lineWidthPoints, metrics.symbolWidthPoints.motorway)
        XCTAssertEqual(streetFill.minimumWidthPoints, 0)
        XCTAssertEqual(streetFill.color, configuration.layers.roads.motorway)
        XCTAssertEqual(streetFill.pointWidthRamp, ramp,
                       "the street era states the overview era's ramp, so z11 to z12 shows no step")

        // A tunnel keeps the tunnel opacity on the same stroke.
        let tunnel = makeStyle(style, layerName: "roads", kind: "highway", kindDetail: "motorway", zoom: 8,
                               extraProperties: ["is_tunnel": .bool(true)])
        XCTAssertLessThan(tunnel.resolvedLineRenderPasses[0].color.w, fill.color.w)

        // Rivers carry a width floor so they read from the z9 tiles the
        // basemap first ships them in.
        let river = makeStyle(style, layerName: "water", kind: "river", zoom: 9, geometry: .linestring)
        XCTAssertNotEqual(river.key, 0)
        XCTAssertEqual(river.minimumWidthPoints, 0.7)
        // A culverted stream stays on the map at the tunnel opacity, on its
        // own key, so it never shares a colour slot with the open water.
        for culvertTag in [["tunnel": MvtValue.string("culvert")], ["layer": MvtValue.int(-1)]] {
            let culvert = makeStyle(style, layerName: "water", kind: "stream", zoom: 14, geometry: .linestring,
                                    extraProperties: culvertTag)
            XCTAssertNotEqual(culvert.key, 0)
            XCTAssertNotEqual(culvert.key, river.key)
            XCTAssertLessThan(culvert.color.w, river.color.w)
        }
    }

    func testGlobalPaletteUpdateChangesPreparedTileRevision() {
        let originalConfiguration = ProtomapsBasemapTheme.default
        let updatedConfiguration = originalConfiguration.layers { layers in
            layers.water = SIMD4<Float>(0.1, 0.2, 0.3, 1.0)
        }

        XCTAssertNotEqual(originalConfiguration.cacheFingerprint,
                          updatedConfiguration.cacheFingerprint)
        XCTAssertNotEqual(ProtomapsBasemapDefaultMapStyle(theme: originalConfiguration)
                            .cacheFingerprint,
                          ProtomapsBasemapDefaultMapStyle(theme: updatedConfiguration)
                            .cacheFingerprint)
    }

    func testEveryPoiWaitsForItsZoomAndTakesAnIcon() {
        let style = ProtomapsBasemapDefaultMapStyle(theme: .default)

        // A POI shows from the zoom the basemap ranks it at, and a
        // street-level service no earlier than the service zoom.
        let hospitalStyle = makeStyle(style, layerName: "pois", kind: "hospital", minZoom: 12, zoom: 14, geometry: .point)
        XCTAssertEqual(hospitalStyle.labelMinCameraZoom, 12)
        let fuelStyle = makeStyle(style, layerName: "pois", kind: "fuel", minZoom: 15, zoom: 14, geometry: .point)
        XCTAssertEqual(fuelStyle.labelMinCameraZoom, 17)
        XCTAssertLessThan(hospitalStyle.labelRank, fuelStyle.labelRank, "the earlier POI ranks first")

        // A category outside the icon set draws its name alone.
        let officeStyle = makeStyle(style, layerName: "pois", kind: "office", minZoom: 12, zoom: 14, geometry: .point)
        XCTAssertNotEqual(officeStyle.key, 0)
        XCTAssertNil(officeStyle.pointLabelStyle?.icon)

        // The street furniture draws as well, each with its symbol.
        for (kind, icon) in [("bus_stop", PoiSpriteIcon?.some(.transit)), ("parking", .parking), ("atm", .bank),
                             ("toilets", .toilets), ("station", .train), ("bench", nil),
                             ("place_of_worship", .worship), ("religious_administration", .worship)] {
            let poi = makeStyle(style, layerName: "pois", kind: kind, minZoom: 16, zoom: 15, geometry: .point)
            XCTAssertNotEqual(poi.key, 0, kind)
            XCTAssertEqual(poi.pointLabelStyle?.icon, icon, kind)
        }

        // The sprite beside the name is the style's choice, stated on the
        // label style: the engine draws what it is handed and reads no tag.
        XCTAssertEqual(hospitalStyle.pointLabelStyle?.icon, .hospital)
        XCTAssertEqual(makeStyle(style, layerName: "pois", kind: "cafe", minZoom: 14, zoom: 14, geometry: .point)
            .pointLabelStyle?.icon, .cafe)
        XCTAssertEqual(ProtomapsBasemapDefaultMapStyle.poiIcon(kind: "supermarket"), .shopping)
        XCTAssertEqual(ProtomapsBasemapDefaultMapStyle.poiIcon(kind: "fuel"), .gasStation)
        XCTAssertEqual(ProtomapsBasemapDefaultMapStyle.poiIcon(kind: "peak"), .viewpoint)
        XCTAssertNil(ProtomapsBasemapDefaultMapStyle.poiIcon(kind: "office"))

        // The landmarks take their own keys.
        XCTAssertEqual(makeStyle(style, layerName: "pois", kind: "peak", minZoom: 10, zoom: 12, geometry: .point).key, 74)
        XCTAssertEqual(makeStyle(style, layerName: "pois", kind: "aerodrome", minZoom: 8, zoom: 12, geometry: .point).key, 75)
        XCTAssertEqual(makeStyle(style, layerName: "pois", kind: "aerodrome", minZoom: 8, zoom: 12, geometry: .point)
            .pointLabelStyle?.icon, .airport)
    }

    func testPoiMinimumZoomFloorsEveryPoiAboveTheStatedZoom() {
        let style = ProtomapsBasemapDefaultMapStyle(
            theme: .default.labelVisibility { visibility in
                visibility.poiMinimumZoom = 30
            }
        )

        // The floor wins over the basemap's zoom, so a value above the
        // camera's maximum zoom hides POIs entirely.
        let hospitalStyle = makeStyle(style, layerName: "pois", kind: "hospital", minZoom: 12, zoom: 14, geometry: .point)
        XCTAssertEqual(hospitalStyle.labelMinCameraZoom, 30)
        let shopStyle = makeStyle(style, layerName: "pois", kind: "supermarket", minZoom: 15, zoom: 14, geometry: .point)
        XCTAssertEqual(shopStyle.labelMinCameraZoom, 30)
    }

    func testPoiMinimumZoomChangesPreparedTileRevision() {
        let original = ProtomapsBasemapTheme.default
        let updated = original.labelVisibility { visibility in
            visibility.poiMinimumZoom = 30
        }

        XCTAssertNotEqual(original.cacheFingerprint, updated.cacheFingerprint)
        XCTAssertNotEqual(ProtomapsBasemapDefaultMapStyle(theme: original).cacheFingerprint,
                          ProtomapsBasemapDefaultMapStyle(theme: updated).cacheFingerprint)
    }

    /// A POI the icon set cannot depict draws its name alone by default, and a configuration can leave such POIs out or hold them
    /// back to a zoom.
    func testAnIconlessPoiDrawsUnlessTheConfigurationLeavesItOut() {
        let byDefault = ProtomapsBasemapDefaultMapStyle(theme: .default)
        XCTAssertNotEqual(makeStyle(byDefault, layerName: "pois", kind: "office", minZoom: 12, zoom: 14, geometry: .point).key, 0)
        XCTAssertNotEqual(makeStyle(byDefault, layerName: "pois", kind: "monument", minZoom: 12, zoom: 15, geometry: .point).key, 0)

        let iconOnly = ProtomapsBasemapDefaultMapStyle(
            theme: .default.labelVisibility { visibility in
                visibility.poiRequiresIcon = true
            }
        )
        XCTAssertEqual(makeStyle(iconOnly, layerName: "pois", kind: "office", minZoom: 12, zoom: 14, geometry: .point).key, 0)
        // A category with an icon is untouched.
        XCTAssertNotEqual(makeStyle(iconOnly, layerName: "pois", kind: "museum", minZoom: 12, zoom: 14, geometry: .point).key, 0)

        let heldBack = ProtomapsBasemapDefaultMapStyle(
            theme: .default.labelVisibility { visibility in
                visibility.poiIconlessMinimumZoom = 16
            }
        )
        let officeStyle = makeStyle(heldBack, layerName: "pois", kind: "office", minZoom: 12, zoom: 14, geometry: .point)
        XCTAssertEqual(officeStyle.labelMinCameraZoom, 16, "it arrives at the iconless floor")
    }

    /// The zooms the names of the lands leave at and the tracking of a
    /// label's letters are baked into the prepared tiles.
    func testTheLandNamesZoomsAndTheTrackingChangeThePreparedTileRevision() {
        let original = ProtomapsBasemapTheme.default
        let zooms = original.labelVisibility { visibility in
            visibility.countryMaximumZoom = 6
        }
        XCTAssertNotEqual(original.cacheFingerprint, zooms.cacheFingerprint)
        let regionZooms = original.labelVisibility { visibility in
            visibility.regionMaximumZoom = 12
        }
        XCTAssertNotEqual(original.cacheFingerprint, regionZooms.cacheFingerprint)
        var tracking = original
        tracking.labels.country.letterSpacingEm += 0.1
        XCTAssertNotEqual(original.cacheFingerprint, tracking.cacheFingerprint)
        var region = original
        region.labels.region.sizePoints += 1
        XCTAssertNotEqual(original.cacheFingerprint, region.cacheFingerprint)
        var opacity = original
        opacity.labels.country.opacity = 1
        XCTAssertNotEqual(original.cacheFingerprint, opacity.cacheFingerprint)
    }

    func testPoiRequiresIconChangesPreparedTileRevision() {
        let original = ProtomapsBasemapTheme.default
        let updated = original.labelVisibility { visibility in
            visibility.poiRequiresIcon = true
        }

        XCTAssertNotEqual(original.cacheFingerprint, updated.cacheFingerprint)
        XCTAssertNotEqual(ProtomapsBasemapDefaultMapStyle(theme: original).cacheFingerprint,
                          ProtomapsBasemapDefaultMapStyle(theme: updated).cacheFingerprint)
    }

    func testIconlessPoiZoomChangesPreparedTileRevision() {
        let original = ProtomapsBasemapTheme.default
        let updated = original.labelVisibility { visibility in
            visibility.poiIconlessMinimumZoom = 14
        }

        XCTAssertNotEqual(original.cacheFingerprint, updated.cacheFingerprint)
        XCTAssertNotEqual(ProtomapsBasemapDefaultMapStyle(theme: original).cacheFingerprint,
                          ProtomapsBasemapDefaultMapStyle(theme: updated).cacheFingerprint)
    }

    func testBoundaryStyleSuppressesPolygonFill() {
        let style = ProtomapsBasemapDefaultMapStyle(theme: .default)

        // Boundaries are a line style: areal geometry must not be filled.
        XCTAssertTrue(makeStyle(style, layerName: "boundaries", kind: "region", zoom: 6).suppressPolygonFill)

        // Regular areal layers still fill polygons as before.
        XCTAssertFalse(makeStyle(style, layerName: "water", zoom: 6, geometry: .polygon).suppressPolygonFill)
    }

    func testBoundaryWidthIsPointLockedWithFeatheredButtDashes() {
        let style = ProtomapsBasemapDefaultMapStyle(theme: .default)

        // Borders resolve their visible width in screen space, so they hold a
        // designed point width instead of pumping with the tile scale, and at
        // every tile zoom where they draw the request is the same.
        for zoom in [4, 8, 12] {
            let boundary = makeStyle(style, layerName: "boundaries", kind: "region", zoom: zoom)
            XCTAssertEqual(boundary.lineWidthPoints, 1.1, "a region border at z\(zoom)")
        }

        // The dash pattern is point-locked and shader-cut: the tessellation
        // stays a continuous solid ribbon (no unit dashes, no caps), and the
        // dash lengths live in points on the style.
        let boundary = makeStyle(style, layerName: "boundaries", kind: "region", zoom: 5)
        XCTAssertFalse(boundary.lineGeometry.usesDashPattern)
        XCTAssertFalse(boundary.lineGeometry.lineCapRound)
        XCTAssertGreaterThan(boundary.dashLengthPoints, 0)
        XCTAssertGreaterThan(boundary.dashGapPoints, 0)

        // A disputed border keeps the stroke and takes a short dash.
        let disputed = makeStyle(style, layerName: "boundaries", kind: "country", zoom: 5,
                                 extraProperties: ["disputed": .bool(true)])
        XCTAssertEqual(disputed.lineWidthPoints, 1.0)
        XCTAssertLessThan(disputed.dashLengthPoints, boundary.dashLengthPoints)

        // A road is a symbol: from the street era on it draws the theme's
        // width in points for its class (the shader holds that width on
        // screen until the world lock zoom), never a width in world units.
        let motorway = makeStyle(style, layerName: "roads", kind: "highway", kindDetail: "motorway", zoom: 12)
        let motorwayWidth = ProtomapsBasemapTheme.default.roadMetrics.symbolWidthPoints.motorway
        XCTAssertEqual(motorway.lineWidthPoints, motorwayWidth)
        XCTAssertFalse(motorway.resolvedLineRenderPasses.isEmpty)
        for pass in motorway.resolvedLineRenderPasses {
            XCTAssertGreaterThan(pass.lineWidthPoints, 0, "Every pass of the symbol has a width in points")
        }
    }

    func testEveryBoundaryLevelDrawsAtEveryZoom() {
        let style = ProtomapsBasemapDefaultMapStyle(theme: .default)

        // Every level the tile ships draws: the regions from the planet
        // view, the counties and the municipalities thinner than a region.
        let region = makeStyle(style, layerName: "boundaries", kind: "region", zoom: 8)
        for zoom in [0, 2, 3, 4, 10, 15] {
            XCTAssertNotEqual(makeStyle(style, layerName: "boundaries", kind: "region", zoom: zoom).key, 0,
                              "a region at z\(zoom)")
            for kind in ["county", "locality", "map_unit", "overlay_limit", "unrecognized_country"] {
                XCTAssertNotEqual(makeStyle(style, layerName: "boundaries", kind: kind, zoom: zoom).key, 0,
                                  "\(kind) at z\(zoom)")
            }
        }
        let county = makeStyle(style, layerName: "boundaries", kind: "county", zoom: 10)
        XCTAssertLessThan(county.lineWidthPoints, region.lineWidthPoints)
        XCTAssertLessThan(county.key, region.key, "a county draws under a region")
        // An unrecognised country draws dashed like a disputed border, on
        // its own key, while a recognised one is the solid line.
        let country = makeStyle(style, layerName: "boundaries", kind: "country", zoom: 5)
        let unrecognized = makeStyle(style, layerName: "boundaries", kind: "unrecognized_country", zoom: 5)
        XCTAssertGreaterThan(unrecognized.dashLengthPoints, 0)
        XCTAssertEqual(country.dashLengthPoints, 0)
        XCTAssertNotEqual(unrecognized.key, country.key)
        let disputedCountry = makeStyle(style, layerName: "boundaries", kind: "country", zoom: 5,
                                        extraProperties: ["disputed": .bool(true)])
        XCTAssertEqual(disputedCountry.dashLengthPoints, unrecognized.dashLengthPoints)
        XCTAssertEqual(disputedCountry.key, unrecognized.key)

        // Country borders stay, solid at every zoom, the atlas convention,
        // while the regions keep their dashes, and the national line is
        // the stronger colour of the two at every zoom: deeper and more
        // opaque than the regional one.
        for zoom in [1, 2, 5, 10] {
            let country = makeStyle(style, layerName: "boundaries", kind: "country", zoom: zoom)
            XCTAssertNotEqual(country.key, 0)
            XCTAssertEqual(country.lineWidthPoints, 1.0)
            XCTAssertEqual(country.dashLengthPoints, 0, "A solid national border at z\(zoom)")
            XCTAssertEqual(country.dashGapPoints, 0, "z\(zoom)")
            let region = makeStyle(style, layerName: "boundaries", kind: "region", zoom: zoom)
            XCTAssertEqual(region.dashLengthPoints, 7.0, "A dashed regional border at z\(zoom)")
            XCTAssertGreaterThan(country.color.w, region.color.w, "The national border is more opaque at z\(zoom)")
            let purple = ProtomapsBasemapTheme.default.layers.boundary
            func distanceFromWhite(_ color: SIMD4<Float>) -> Float {
                let gap = SIMD3<Float>(1, 1, 1) - SIMD3<Float>(color.x, color.y, color.z)
                return (gap * gap).sum().squareRoot()
            }
            XCTAssertGreaterThan(distanceFromWhite(country.color), distanceFromWhite(region.color),
                                 "The national border is the deeper purple at z\(zoom)")
            XCTAssertLessThanOrEqual(distanceFromWhite(country.color), distanceFromWhite(purple) + 0.001)
        }
    }

    func testBuildingsDrawOnEveryTileAndAnAddressPointIsAHouseNumber() {
        let style = ProtomapsBasemapDefaultMapStyle(theme: .default)
        for zoom in [12, 13, 15] {
            let building = makeStyle(style, layerName: "buildings", kind: "building", zoom: zoom, geometry: .polygon)
            XCTAssertNotNil(building.extrusionStyle, "z\(zoom)")
            XCTAssertGreaterThan(building.extrusionFallbackHeight, 0,
                                 "a building the tile states no height for still rises")
        }
        let number = makeStyle(style, layerName: "buildings", kind: "address", zoom: 15, geometry: .point,
                               extraProperties: ["addr_housenumber": .string("12A")])
        XCTAssertNotNil(number.labelTextStyle)
        XCTAssertNil(number.pointLabelStyle?.icon)
        let poi = makeStyle(style, layerName: "pois", kind: "cafe", minZoom: 18, zoom: 15, geometry: .point)
        XCTAssertGreaterThan(number.labelCollisionRank, poi.labelCollisionRank, "a house number yields to every POI")
        XCTAssertEqual(makeStyle(style, layerName: "buildings", kind: "address", zoom: 15, geometry: .point).key, 0,
                       "an address point without a number draws nothing")
    }

    private func makeStyle(_ style: ProtomapsBasemapDefaultMapStyle,
                           layerName: String,
                           kind: String? = nil,
                           kindDetail: String? = nil,
                           minZoom: Int? = nil,
                           zoom: Int,
                           geometry: MvtGeometryType = .unknown,
                           extraProperties: [String: MvtValue] = [:]) -> FeatureStyle {
        var properties: [String: MvtValue] = extraProperties
        if let kind {
            properties["kind"] = .string(kind)
        }
        if let kindDetail {
            properties["kind_detail"] = .string(kindDetail)
        }
        if let minZoom {
            properties["min_zoom"] = .int(Int64(minZoom))
        }
        if layerName == "pois" || layerName == "places", properties["name"] == nil {
            properties["name"] = .string("Test")
        }
        return style.makeStyle(
            data: DetFeatureStyleData(layerName: layerName,
                                      properties: properties,
                                      tile: Tile(x: 0, y: 0, z: zoom),
                                      geometryType: geometry)
        )
    }
}
