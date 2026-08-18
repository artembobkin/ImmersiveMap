// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class ImmersiveMapTilesDefaultMapStyleTests: XCTestCase {
    func testGroundStylesBakeBothPalettesForTheContinuousHandover() {
        let configuration = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: configuration)

        // Every ground style bakes its overview color and its street
        // counterpart, at EVERY tile zoom: the shader lerps between them per
        // frame from camera zoom, so the rendered color is identical on both
        // sides of any tile swap and no zoom boundary can flip the map.
        for zoom in [2, 8, 9, 10, 12] {
            let water = makeStyle(style, layerName: "water", zoom: zoom)
            XCTAssertEqual(water.color, configuration.globalLandcover.water, "z\(zoom)")
            XCTAssertEqual(water.streetColor, configuration.layers.water, "z\(zoom)")
        }
        for zoom in [8, 9, 10, 12] {
            let background = makeStyle(style, layerName: "background", zoom: zoom)
            XCTAssertEqual(background.color, configuration.globalLandcover.land, "z\(zoom)")
            XCTAssertEqual(background.streetColor, configuration.layers.land, "z\(zoom)")
        }

        // A WorldCover biome's street color is the OSM class that replaces
        // it, and the replacing OSM class enters wearing the biome's color:
        // through the handover both lerp along the same segment, so the swap
        // changes geometry, never the color language.
        let biomeForest = makeStyle(style, layerName: "globallandcover", className: "forest", zoom: 9)
        XCTAssertEqual(biomeForest.streetColor, configuration.layers.wood)
        let osmWood = makeStyle(style, layerName: "landcover", className: "wood", zoom: 10)
        XCTAssertEqual(osmWood.color, configuration.globalLandcover.forest)
        XCTAssertEqual(osmWood.streetColor, configuration.layers.wood)

        // Cities render: the WorldCover urban class is a soft gray with the
        // OSM residential beige as its street counterpart.
        let urban = makeStyle(style, layerName: "globallandcover", className: "urban", zoom: 6)
        XCTAssertEqual(urban.key, 10)
        XCTAssertEqual(urban.streetColor, configuration.layers.residential)

        // Styles outside the handover bake the same color twice.
        let boundary = makeStyle(style, layerName: "boundary", adminLevel: 2, zoom: 9)
        XCTAssertNil(boundary.streetColor)
    }

    func testStreetPaletteBlendIsContinuousAcrossTheHandoverBand() {
        XCTAssertEqual(LowZoomOverviewFade.streetPaletteBlend(for: 7.0), 0.0)
        XCTAssertEqual(LowZoomOverviewFade.streetPaletteBlend(for: 8.0), 0.0)
        XCTAssertEqual(LowZoomOverviewFade.streetPaletteBlend(for: 11.5), 1.0)
        XCTAssertEqual(LowZoomOverviewFade.streetPaletteBlend(for: 14.0), 1.0)
        // Strictly monotone through the band, with no step bigger than a
        // smooth ramp allows: this is the property the per-tile-zoom bridge
        // could not have.
        var previous = LowZoomOverviewFade.streetPaletteBlend(for: 8.0)
        var zoom = 8.05
        while zoom < 11.5 {
            let value = LowZoomOverviewFade.streetPaletteBlend(for: zoom)
            XCTAssertGreaterThan(value, previous, "zoom \(zoom)")
            XCTAssertLessThan(value - previous, 0.03, "zoom \(zoom)")
            previous = value
            zoom += 0.05
        }
    }

    func testMassiveOverviewMergesVegetationClassesThroughZoomTwo() {
        let configuration = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault
        let colors = configuration.globalLandcover
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: configuration)
        let mergedClasses = ["land", "grass", "shrub", "moss", "crop", "wetland", "mangroves"]

        for className in mergedClasses {
            XCTAssertEqual(makeStyle(style,
                                     layerName: "globallandcover",
                                     className: className,
                                     zoom: 2).color,
                           colors.grass,
                           "Expected massive overview color for \(className)")
        }

        let overviewForest = colors.grass + (colors.forest - colors.grass) * 0.25
        XCTAssertEqual(makeStyle(style,
                                 layerName: "globallandcover",
                                 className: "forest",
                                 zoom: 2).color,
                       overviewForest)
        // Past the full merge the blend releases quickly: the merge exists
        // for the globe, and holding it into the country zooms turned a
        // farmed plain into camouflage. At z3 vegetation sits halfway toward
        // the shared tone (forests three quarters of that), and from z8 the
        // palette is unmixed.
        func blended(_ base: SIMD4<Float>, amount: Float) -> SIMD4<Float> {
            base + (colors.grass - base) * amount
        }
        XCTAssertEqual(makeStyle(style,
                                 layerName: "globallandcover",
                                 className: "land",
                                 zoom: 3).color,
                       blended(colors.land, amount: 0.5))
        XCTAssertEqual(makeStyle(style,
                                 layerName: "globallandcover",
                                 className: "crop",
                                 zoom: 3).color,
                       blended(colors.crop, amount: 0.5))
        XCTAssertEqual(makeStyle(style,
                                 layerName: "globallandcover",
                                 className: "forest",
                                 zoom: 3).color,
                       blended(colors.forest, amount: 0.5 * 0.75))
        // At z9 the vegetation blend has fully released: the overview color
        // is the raw palette (the street handover happens per frame in the
        // shader, not in the baked color).
        XCTAssertEqual(makeStyle(style,
                                 layerName: "globallandcover",
                                 className: "forest",
                                 zoom: 9).color,
                       colors.forest)
    }

    func testGlobalLandcoverClassesUseDedicatedSoftBiomesColors() {
        let configuration = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault
        let colors = configuration.globalLandcover
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: configuration)
        // z8 is the last zoom before the street handover begins; the
        // vegetation blend has fully released by then, so the palette is
        // raw. One key per class.
        let expected: [(String, UInt8, SIMD4<Float>)] = [
            ("land", 2, colors.land),
            ("barren", 3, colors.barren),
            ("grass", 4, colors.grass),
            ("shrub", 4, colors.grass),
            ("moss", 4, colors.grass),
            ("crop", 5, colors.crop),
            ("forest", 6, colors.forest),
            ("wetland", 7, colors.wetland),
            ("mangroves", 7, colors.wetland),
            ("snow", 8, colors.snow)
        ]

        for (className, key, color) in expected {
            let featureStyle = makeStyle(style,
                                         layerName: "globallandcover",
                                         className: className,
                                         zoom: 8)
            XCTAssertEqual(featureStyle.key, key, "Unexpected key for \(className)")
            XCTAssertEqual(featureStyle.color, color, "Unexpected color for \(className)")
        }
    }

    func testRoadClassesAppearByZoom() {
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: .immersiveMapTilesDefault)

        func key(_ className: String, zoom: Int) -> UInt8 {
            makeStyle(style, layerName: "transportation", className: className, zoom: zoom).key
        }

        // Majors wait for the zoom where the source's network is whole
        // (below tile z6 only motorway-class geometry exists, so corridors
        // would show cut off mid-line); each further class joins at the zoom
        // it can carry meaning.
        for (className, minimumZoom) in [("motorway", 5), ("trunk", 5),
                                         ("primary", 7), ("ferry", 8), ("secondary", 9),
                                         ("tertiary", 10), ("rail", 10), ("minor", 12),
                                         ("service", 13), ("path", 14)] {
            XCTAssertEqual(key(className, zoom: minimumZoom - 1), 0,
                           "\(className) must hide below z\(minimumZoom)")
            XCTAssertNotEqual(key(className, zoom: minimumZoom), 0,
                              "\(className) must draw from z\(minimumZoom)")
        }
    }

    func testRoadsFadeInThroughTheRoadBand() {
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: .immersiveMapTilesDefault)
        let motorway = makeStyle(style, layerName: "transportation", className: "motorway", zoom: 6)
        XCTAssertEqual(motorway.lowZoomFadeMask, 2.0)
        for pass in motorway.resolvedLineRenderPasses {
            XCTAssertEqual(pass.lowZoomFadeMask, 2.0)
        }
        let rail = makeStyle(style, layerName: "transportation", className: "rail", zoom: 10)
        XCTAssertEqual(rail.lowZoomFadeMask, 2.0)
    }

    func testRoadCasingKeysSortBelowEveryFill() {
        // Below the separate-road zoom the generic ground path draws by
        // ascending key, and the intent is casing first with the fill
        // overdrawing it, so every casing key must sort below every fill key
        // (and above the building footprints at 30). Keys stay distinct so
        // classes keep their relative layering.
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: .immersiveMapTilesDefault)
        var fillKeys: [UInt8] = []
        var casingKeys: [UInt8] = []
        for className in ["motorway", "trunk", "primary", "secondary", "tertiary", "minor", "service"] {
            let roadStyle = makeStyle(style, layerName: "transportation", className: className, zoom: 14)
            for pass in roadStyle.resolvedLineRenderPasses {
                if pass.roadPassRole == .casing {
                    casingKeys.append(pass.key)
                } else if pass.roadPassRole == .fill {
                    fillKeys.append(pass.key)
                }
            }
        }
        XCTAssertFalse(casingKeys.isEmpty)
        XCTAssertEqual(Set(casingKeys).count, casingKeys.count, "Casing keys must stay distinct")
        XCTAssertLessThan(casingKeys.max()!, fillKeys.min()!)
        XCTAssertGreaterThan(casingKeys.min()!, 30)
    }

    func testMajorRoadsHoldAWidthFloorAndAnOverviewAccent() {
        let configuration = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: configuration)

        // The floor keeps the majors readable strokes at region zooms; it is
        // a floor, not a lock, so street-zoom world growth is untouched.
        let motorway = makeStyle(style, layerName: "transportation", className: "motorway", zoom: 7)
        let fill = motorway.resolvedLineRenderPasses.first { $0.roadPassRole == .fill }!
        XCTAssertEqual(fill.minimumWidthPoints, 2.2)
        XCTAssertEqual(fill.lineWidthPoints, 0)

        // The overview accent is the baked color; the light street palette is
        // its continuous street counterpart, released by the same camera-zoom
        // blend as the ground.
        XCTAssertEqual(fill.streetColor, configuration.layers.roads.motorway)
        XCTAssertNotEqual(fill.color, configuration.layers.roads.motorway)

        // Primary has a floor but no accent.
        let primary = makeStyle(style, layerName: "transportation", className: "primary", zoom: 8)
        let primaryFill = primary.resolvedLineRenderPasses.first { $0.roadPassRole == .fill }!
        XCTAssertEqual(primaryFill.minimumWidthPoints, 1.6)
        XCTAssertNil(primaryFill.streetColor)
        XCTAssertEqual(primaryFill.color, configuration.layers.roads.primary)
    }

    func testConstructionClassesFollowTheirBaseClass() {
        let configuration = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: configuration)

        // The low-zoom tiles ship the construction variant right alongside
        // the base class; hiding it cut corridors mid-line. It gates like the
        // base class and draws point-dashed, without casing or the overview
        // accent.
        let construction = makeStyle(style, layerName: "transportation",
                                     className: "motorway_construction", zoom: 6)
        XCTAssertNotEqual(construction.key, 0)
        let fill = construction.resolvedLineRenderPasses.first { $0.roadPassRole == .fill }!
        XCTAssertGreaterThan(fill.dashLengthPoints, 0)
        XCTAssertEqual(fill.color, configuration.layers.roads.motorway)
        XCTAssertNil(fill.streetColor)
        XCTAssertFalse(construction.resolvedLineRenderPasses.contains { $0.roadPassRole == .casing })
        XCTAssertEqual(makeStyle(style, layerName: "transportation",
                                 className: "motorway_construction", zoom: 12)
            .resolvedLineRenderPasses.contains { $0.roadPassRole == .casing }, false)

        // Rivers carry a width floor so they read from the z3 tiles the
        // source first ships them in.
        let river = makeStyle(style, layerName: "waterway", className: "river", zoom: 3)
        XCTAssertNotEqual(river.key, 0)
        XCTAssertEqual(river.minimumWidthPoints, 0.7)

        // A construction variant of a gated class stays gated with the base.
        XCTAssertEqual(makeStyle(style, layerName: "transportation",
                                 className: "primary_construction", zoom: 6).key, 0)
        XCTAssertNotEqual(makeStyle(style, layerName: "transportation",
                                    className: "primary_construction", zoom: 7).key, 0)
    }

    func testRoadCasingJoinsOnlyFromTileZoomTen() {
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: .immersiveMapTilesDefault)
        func hasCasing(_ className: String, zoom: Int) -> Bool {
            makeStyle(style, layerName: "transportation", className: className, zoom: zoom)
                .resolvedLineRenderPasses.contains { $0.roadPassRole == .casing }
        }
        // Below tile z10 the fill is under about two points and a casing
        // cannot render as an edge: majors draw as clean single strokes.
        XCTAssertFalse(hasCasing("motorway", zoom: 7))
        XCTAssertFalse(hasCasing("primary", zoom: 9))
        XCTAssertTrue(hasCasing("motorway", zoom: 10))
        XCTAssertTrue(hasCasing("tertiary", zoom: 12))
    }

    func testGlobalPaletteUpdateChangesPreparedTileRevision() {
        let originalConfiguration = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault
        let updatedConfiguration = originalConfiguration.globalLandcover { colors in
            colors.water = SIMD4<Float>(0.1, 0.2, 0.3, 1.0)
        }

        XCTAssertNotEqual(originalConfiguration.cacheFingerprint,
                          updatedConfiguration.cacheFingerprint)
        XCTAssertNotEqual(ImmersiveMapTilesDefaultMapStyle(configuration: originalConfiguration)
                            .preparedTileStyleRevision,
                          ImmersiveMapTilesDefaultMapStyle(configuration: updatedConfiguration)
                            .preparedTileStyleRevision)
    }

    func testPoiMinCameraZoomDerivesFromOverzoomBudgetAndPriorities() {
        // Appearance threshold = tile.z + log4(effRank / budget): the cell
        // budget quadruples per overzoom zoom level. There are no absolute zoom
        // ramps, so the approach survives a change of the source's maxzoom.
        let style = ImmersiveMapTilesDefaultMapStyle(
            configuration: .immersiveMapTilesDefault
        )

        // Anchor (hospital): the negative offset is clamped into the budget,
        // visible from the tile's birth regardless of rank.
        let hospitalStyle = makeStyle(style, layerName: "poi", className: "hospital", rank: 20, zoom: 14)
        XCTAssertEqual(hospitalStyle.labelMinCameraZoom, 14)

        // Neutral commerce (shop, rank 2): log4(2) = 0.5 zoom of overzoom.
        let shopStyle = makeStyle(style, layerName: "poi", className: "shop", rank: 2, zoom: 14)
        XCTAssertEqual(shopStyle.labelMinCameraZoom, 14.5, accuracy: 0.001)

        // The rank tail arrives later: log4(20) ~ 2.16 zooms.
        let deepRankStyle = makeStyle(style, layerName: "poi", className: "shop", rank: 20, zoom: 14)
        XCTAssertEqual(deepRankStyle.labelMinCameraZoom, 14 + log2(Float(20)) / 2, accuracy: 0.001)

        // Infrastructure (bus, rank 2): offset +40 -> log4(42) ~ 2.7 zooms.
        let busStyle = makeStyle(style, layerName: "poi", className: "bus", rank: 2, zoom: 14)
        XCTAssertEqual(busStyle.labelMinCameraZoom, 14 + log2(Float(42)) / 2, accuracy: 0.001)

        // Iconless POI (class "office" outside the icon set): the configurable
        // iconless threshold (16) remains the lower bound.
        let officeStyle = makeStyle(style, layerName: "poi", className: "office", rank: 2, zoom: 14)
        XCTAssertEqual(officeStyle.labelMinCameraZoom, 16)

        // Zoom agnosticism: the same shop in a z13 tile appears one zoom earlier.
        let earlierTileStyle = makeStyle(style, layerName: "poi", className: "shop", rank: 2, zoom: 13)
        XCTAssertEqual(earlierTileStyle.labelMinCameraZoom, 13.5, accuracy: 0.001)
    }

    func testPoiMinimumZoomFloorsEveryPoiAboveRankAndOverzoomThresholds() {
        let style = ImmersiveMapTilesDefaultMapStyle(
            configuration: .immersiveMapTilesDefault.labelVisibility { visibility in
                visibility.poiMinimumZoom = 30
            }
        )

        // The floor wins over both the from-birth anchor threshold and the
        // overzoom-delay cap (tile.z + 3.5), so a value above the camera's
        // maximum zoom hides POIs entirely.
        let hospitalStyle = makeStyle(style, layerName: "poi", className: "hospital", rank: 20, zoom: 14)
        XCTAssertEqual(hospitalStyle.labelMinCameraZoom, 30)
        let shopStyle = makeStyle(style, layerName: "poi", className: "shop", rank: 2, zoom: 14)
        XCTAssertEqual(shopStyle.labelMinCameraZoom, 30)
    }

    func testPoiMinimumZoomChangesPreparedTileRevision() {
        let original = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault
        let updated = original.labelVisibility { visibility in
            visibility.poiMinimumZoom = 30
        }

        XCTAssertNotEqual(original.cacheFingerprint, updated.cacheFingerprint)
        XCTAssertNotEqual(ImmersiveMapTilesDefaultMapStyle(configuration: original).preparedTileStyleRevision,
                          ImmersiveMapTilesDefaultMapStyle(configuration: updated).preparedTileStyleRevision)
    }

    func testIconlessPoiZoomChangesPreparedTileRevision() {
        let original = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault
        let updated = original.labelVisibility { visibility in
            visibility.poiIconlessMinimumZoom = 14
        }

        XCTAssertNotEqual(original.cacheFingerprint, updated.cacheFingerprint)
        XCTAssertNotEqual(ImmersiveMapTilesDefaultMapStyle(configuration: original).preparedTileStyleRevision,
                          ImmersiveMapTilesDefaultMapStyle(configuration: updated).preparedTileStyleRevision)
    }

    func testBoundaryStyleSuppressesPolygonFill() {
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: .immersiveMapTilesDefault)

        // Boundaries are a line style: areal geometry (e.g. Native American
        // reservations arriving as polygons) must not be filled.
        XCTAssertTrue(makeStyle(style, layerName: "boundary", zoom: 6).suppressPolygonFill)

        // Regular areal layers still fill polygons as before.
        XCTAssertFalse(makeStyle(style, layerName: "water", zoom: 6).suppressPolygonFill)
    }

    func testBoundaryWidthIsPointLockedWithFeatheredButtDashes() {
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: .immersiveMapTilesDefault)

        // Borders resolve their visible width in screen space, so they hold a
        // designed point width instead of pumping with the tile scale, and at
        // every tile zoom where they draw the request is the same.
        for zoom in [4, 8, 12] {
            let boundary = makeStyle(style, layerName: "boundary", zoom: zoom)
            XCTAssertEqual(boundary.lineWidthPoints, 1.1, "admin_level defaults to 4 at z\(zoom)")
        }

        // The dash pattern is point-locked and shader-cut: the tessellation
        // stays a continuous solid ribbon (no unit dashes, no caps), and the
        // dash lengths live in points on the style.
        let boundary = makeStyle(style, layerName: "boundary", zoom: 5)
        XCTAssertFalse(boundary.parseGeometryStyleData.usesDashPattern)
        XCTAssertFalse(boundary.parseGeometryStyleData.lineCapRound)
        XCTAssertGreaterThan(boundary.dashLengthPoints, 0)
        XCTAssertGreaterThan(boundary.dashGapPoints, 0)

        // Roads stay world-locked: their width growing with zoom is the
        // designed behavior at street level.
        let motorway = makeStyle(style, layerName: "transportation", className: "motorway", zoom: 12)
        XCTAssertEqual(motorway.lineWidthPoints, 0)
        for pass in motorway.resolvedLineRenderPasses {
            XCTAssertEqual(pass.lineWidthPoints, 0)
        }
    }

    func testPlanetZoomBoundariesShowCountriesOnly() {
        let style = ImmersiveMapTilesDefaultMapStyle(configuration: .immersiveMapTilesDefault)

        // Regional (admin 3-4) borders are clutter over a planet or continent
        // view: hidden below the regional zoom, present from it on.
        for zoom in [0, 2, 3] {
            XCTAssertEqual(makeStyle(style, layerName: "boundary", zoom: zoom).key, 0,
                           "admin_level 4 must hide at z\(zoom)")
        }
        XCTAssertNotEqual(makeStyle(style, layerName: "boundary", zoom: 4).key, 0)

        // Country borders stay, dashed at every zoom: the point-locked dash
        // pattern keeps its designed size, so it reads as dashes rather than
        // dots even over a planet view.
        for zoom in [1, 2, 5, 10] {
            let country = makeStyle(style, layerName: "boundary", adminLevel: 2, zoom: zoom)
            XCTAssertNotEqual(country.key, 0)
            XCTAssertEqual(country.lineWidthPoints, 1.6)
            XCTAssertEqual(country.dashLengthPoints, 7.0, "z\(zoom)")
            XCTAssertEqual(country.dashGapPoints, 3.5, "z\(zoom)")
        }
    }

    private func makeStyle(_ style: ImmersiveMapTilesDefaultMapStyle,
                           layerName: String,
                           className: String? = nil,
                           rank: Int? = nil,
                           adminLevel: Int? = nil,
                           zoom: Int) -> FeatureStyle {
        var properties: [String: VectorTile_Tile.Value] = [:]
        if let className {
            properties["class"] = stringValue(className)
        }
        if let rank {
            var rankValue = VectorTile_Tile.Value()
            rankValue.intValue = Int64(rank)
            properties["rank"] = rankValue
        }
        if let adminLevel {
            var adminLevelValue = VectorTile_Tile.Value()
            adminLevelValue.intValue = Int64(adminLevel)
            properties["admin_level"] = adminLevelValue
        }
        return style.makeStyle(
            data: DetFeatureStyleData(layerName: layerName,
                                      properties: properties,
                                      tile: Tile(x: 0, y: 0, z: zoom))
        )
    }

    private func stringValue(_ value: String) -> VectorTile_Tile.Value {
        var tileValue = VectorTile_Tile.Value()
        tileValue.stringValue = value
        return tileValue
    }
}
