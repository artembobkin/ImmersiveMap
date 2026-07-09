// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class VectorTileLabelDecisionEngineTests: XCTestCase {
    func testRussianPreferencesPreferRussianThenEnglishThenNative() {
        let properties: [String: VectorTile_Tile.Value] = [
            "name": stringValue("Москва"),
            "name_en": stringValue("Moscow"),
            "name_ru": stringValue("Москва")
        ]
        let resolver = VectorTileLabelTextResolver(glyphCoverage: .legacyAtlasForTests)
        let preferences = VectorTileLabelLanguagePreferences.from(settingsLanguage: .russian)

        XCTAssertEqual(preferences.selectedLanguage, .russian)
        XCTAssertEqual(preferences.fallbackPolicy, .international)
        XCTAssertEqual(preferences.fallbackChain.map(\.fieldName), ["name_ru", "name_en", "name"])
        XCTAssertEqual(resolver.resolveText(properties: properties, preferences: preferences), "Москва")
    }

    func testFrenchPreferencesFallBackToEnglishBeforeNativeWhenPreferredNameIsAbsent() {
        let properties: [String: VectorTile_Tile.Value] = [
            "name": stringValue("Москва"),
            "name_en": stringValue("Moscow")
        ]
        let resolver = VectorTileLabelTextResolver(glyphCoverage: .legacyAtlasForTests)
        let preferences = VectorTileLabelLanguagePreferences.from(settingsLanguage: .french)

        XCTAssertEqual(resolver.resolveText(properties: properties, preferences: preferences), "Moscow")
    }

    func testLocalFirstPolicyFallsBackToNativeBeforeEnglishWhenPreferredNameIsAbsent() {
        let properties: [String: VectorTile_Tile.Value] = [
            "name": stringValue("Москва"),
            "name_en": stringValue("Moscow")
        ]
        let resolver = VectorTileLabelTextResolver(glyphCoverage: .legacyAtlasForTests)
        let preferences = VectorTileLabelLanguagePreferences.from(settingsLanguage: .french,
                                                                  fallbackPolicy: .localFirst)

        XCTAssertEqual(preferences.fallbackPolicy, .localFirst)
        XCTAssertEqual(preferences.fallbackChain.map(\.fieldName), ["name_fr", "name", "name_en"])
        XCTAssertEqual(resolver.resolveText(properties: properties, preferences: preferences), "Москва")
    }

    func testRussianPreferencesFallBackToNativeCyrillicWhenRussianAndEnglishNamesAreAbsent() {
        let properties: [String: VectorTile_Tile.Value] = [
            "name": stringValue("Москва")
        ]
        let resolver = VectorTileLabelTextResolver(glyphCoverage: .legacyAtlasForTests)
        let preferences = VectorTileLabelLanguagePreferences.from(settingsLanguage: .russian)

        XCTAssertEqual(resolver.resolveText(properties: properties, preferences: preferences), "Москва")
    }

    func testEnglishPreferencesPreferEnglishThenNative() {
        let properties: [String: VectorTile_Tile.Value] = [
            "name": stringValue("Moscow Native"),
            "name_en": stringValue("Moscow EN"),
            "name_ru": stringValue("Москва")
        ]
        let resolver = VectorTileLabelTextResolver(glyphCoverage: .legacyAtlasForTests)
        let preferences = VectorTileLabelLanguagePreferences.from(settingsLanguage: .english)

        XCTAssertEqual(preferences.selectedLanguage, .english)
        XCTAssertEqual(preferences.fallbackChain.map(\.fieldName), ["name_en", "name"])
        XCTAssertEqual(resolver.resolveText(properties: properties, preferences: preferences), "Moscow EN")
    }

    func testFrenchPreferencesPreferNameFrThenEnglish() {
        let properties: [String: VectorTile_Tile.Value] = [
            "name": stringValue("Paris Native"),
            "name_en": stringValue("Paris EN"),
            "name_fr": stringValue("Paris FR")
        ]
        let resolver = VectorTileLabelTextResolver(glyphCoverage: .legacyAtlasForTests)
        let preferences = VectorTileLabelLanguagePreferences.from(settingsLanguage: .french)

        XCTAssertEqual(preferences.fallbackChain.map(\.fieldName), ["name_fr", "name_en", "name"])
        XCTAssertEqual(resolver.resolveText(properties: properties, preferences: preferences), "Paris FR")
    }

    func testSharedResolverCoversRoadLabelFieldSelection() {
        let properties: [String: VectorTile_Tile.Value] = [
            "name": stringValue("Rue Native"),
            "name_en": stringValue("Rivoli Street"),
            "name_fr": stringValue("Rue de Rivoli")
        ]
        let resolver = VectorTileLabelTextResolver(glyphCoverage: .legacyAtlasForTests)
        let preferences = VectorTileLabelLanguagePreferences.from(settingsLanguage: .french)

        XCTAssertEqual(resolver.resolveText(properties: properties, preferences: preferences), "Rue de Rivoli")
    }

    func testGermanPreferencesFallbackToEnglishWhenPreferredFieldIsMissing() {
        let properties: [String: VectorTile_Tile.Value] = [
            "name_en": stringValue("Munich EN")
        ]
        let resolver = VectorTileLabelTextResolver(glyphCoverage: .legacyAtlasForTests)
        let preferences = VectorTileLabelLanguagePreferences.from(settingsLanguage: .german)

        XCTAssertEqual(resolver.resolveText(properties: properties, preferences: preferences), "Munich EN")
    }

    func testEnglishPreferencesFallBackToNativeLatinWhenEnglishNameIsAbsent() {
        let properties: [String: VectorTile_Tile.Value] = [
            "name": stringValue("Moscow"),
            "name_ru": stringValue("Москва")
        ]
        let resolver = VectorTileLabelTextResolver(glyphCoverage: .legacyAtlasForTests)
        let preferences = VectorTileLabelLanguagePreferences.from(settingsLanguage: .english)

        XCTAssertEqual(resolver.resolveText(properties: properties, preferences: preferences), "Moscow")
    }

    func testEnglishPreferencesFallBackToNativeCyrillicWhenEnglishNameIsAbsent() {
        let properties: [String: VectorTile_Tile.Value] = [
            "name": stringValue("Москва"),
            "name_ru": stringValue("Москва")
        ]
        let resolver = VectorTileLabelTextResolver(glyphCoverage: .legacyAtlasForTests)
        let preferences = VectorTileLabelLanguagePreferences.from(settingsLanguage: .english)

        XCTAssertEqual(resolver.resolveText(properties: properties, preferences: preferences), "Москва")
    }

    func testUnsupportedGlyphCoverageRejectsText() {
        let properties: [String: VectorTile_Tile.Value] = [
            "name": stringValue("東京")
        ]
        let resolver = VectorTileLabelTextResolver(glyphCoverage: .legacyAtlasForTests)
        let preferences = VectorTileLabelLanguagePreferences.from(settingsLanguage: .english)

        XCTAssertNil(resolver.resolveText(properties: properties, preferences: preferences))
    }

    func testProviderFeatureIdentityParticipatesInCrossTileDeduplication() {
        let identity = VectorTileLabelIdentity.providerFeature(providerID: "mapbox",
                                                               layerName: "place_label",
                                                               featureID: 42)

        XCTAssertTrue(identity.participatesInCrossTileDeduplication)
        XCTAssertEqual(identity.runtimeKey, 17424410298459024603)
        XCTAssertEqual(identity.runtimeKey,
                       VectorTileLabelIdentity.providerFeature(providerID: "mapbox",
                                                               layerName: "place_label",
                                                               featureID: 42).runtimeKey)
    }

    func testSemanticIdentityUsesStableRuntimeKey() {
        let identity = VectorTileLabelIdentity.semantic(providerID: "mapbox",
                                                        kind: "place",
                                                        text: "Moscow",
                                                        worldBucket: SIMD2<Int32>(10, 20))

        XCTAssertTrue(identity.participatesInCrossTileDeduplication)
        XCTAssertEqual(identity.runtimeKey, 18093230200447490384)
    }

    func testTileLocalIdentityIncludesTileCoordinates() {
        let first = VectorTileLabelIdentity.tileLocal(tile: Tile(x: 10, y: 20, z: 5),
                                                      layerName: "poi_label",
                                                      text: "Museum",
                                                      anchor: SIMD2<Int16>(100, 200))
        let second = VectorTileLabelIdentity.tileLocal(tile: Tile(x: 11, y: 20, z: 5),
                                                       layerName: "poi_label",
                                                       text: "Museum",
                                                       anchor: SIMD2<Int16>(100, 200))

        XCTAssertFalse(first.participatesInCrossTileDeduplication)
        XCTAssertEqual(first.runtimeKey, 6949302229354522716)
        XCTAssertEqual(second.runtimeKey, 6830255165424541913)
        XCTAssertNotEqual(first.runtimeKey, second.runtimeKey)
    }

    func testMapboxProfileExcludesRoadAndTransitPointLabelLayers() {
        let profile = MapboxVectorTileLabelProviderProfile(settings: .default)

        XCTAssertFalse(profile.includesBasePointLabel(layerName: "road_label",
                                                      properties: [:],
                                                      tileZoom: 15,
                                                      sortKey: 0))
        XCTAssertFalse(profile.includesBasePointLabel(layerName: "transit_stop_label",
                                                      properties: [:],
                                                      tileZoom: 15,
                                                      sortKey: 0))
    }

    func testMapboxProfileAllowsHouseNumberAtConfiguredZoom() {
        let profile = MapboxVectorTileLabelProviderProfile(settings: .default)

        XCTAssertFalse(profile.includesBasePointLabel(layerName: "housenum_label",
                                                      properties: [:],
                                                      tileZoom: 14,
                                                      sortKey: 0))
        XCTAssertTrue(profile.includesBasePointLabel(layerName: "housenum_label",
                                                     properties: [:],
                                                     tileZoom: 15,
                                                     sortKey: 0))
    }

    func testMapboxProfilePushesPoiCollisionBehindSettlementCollision() {
        let profile = MapboxVectorTileLabelProviderProfile(settings: .default)

        XCTAssertLessThan(profile.collisionRank(layerName: "place_label", sortKey: 50),
                          profile.collisionRank(layerName: "poi_label", sortKey: 50))
    }

    func testMapboxProfileSortKeyUsesRankKeyPrecedence() {
        let profile = MapboxVectorTileLabelProviderProfile(settings: .default)

        XCTAssertEqual(profile.sortKey(properties: [
            "symbolrank": intValue(4),
            "rank": intValue(1),
            "labelrank": intValue(2)
        ]), 49)
    }

    func testMapboxProfileSortKeyParsesNumericRankValues() {
        let profile = MapboxVectorTileLabelProviderProfile(settings: .default)
        let rankValues: [(String, VectorTile_Tile.Value)] = [
            ("string", stringValue("7")),
            ("uint", uintValue(7)),
            ("int", intValue(7)),
            ("sint", sintValue(7)),
            ("float", floatValue(7.8)),
            ("double", doubleValue(7.8))
        ]

        for (description, rankValue) in rankValues {
            XCTAssertEqual(profile.sortKey(properties: ["symbolrank": rankValue]),
                           79,
                           description)
        }
    }

    func testMapboxProfileSortKeyUsesMaximumPopulationBoost() {
        let profile = MapboxVectorTileLabelProviderProfile(settings: .default)

        XCTAssertEqual(profile.sortKey(properties: [
            "symbolrank": intValue(20),
            "population": doubleValue(10),
            "pop_max": doubleValue(1_000_000)
        ]), 149)
    }

    func testMapboxProfileSortKeyAppliesCapitalBoostForTruthyValues() {
        let profile = MapboxVectorTileLabelProviderProfile(settings: .default)
        let capitalValues: [(String, VectorTile_Tile.Value)] = [
            ("bool", boolValue(true)),
            ("string", stringValue("yes")),
            ("int", intValue(1))
        ]

        for (description, capitalValue) in capitalValues {
            XCTAssertEqual(profile.sortKey(properties: [
                "symbolrank": intValue(20),
                "capital": capitalValue
            ]), 179, description)
        }
    }

    func testMapboxProfileBuildsProviderFeatureIdentityWhenFeatureIDExists() {
        let profile = MapboxVectorTileLabelProviderProfile(settings: .default)
        let feature = VectorTileLabelFeature(providerID: "mapbox",
                                             tile: Tile(x: 10, y: 20, z: 5),
                                             layerName: "place_label",
                                             featureID: 42,
                                             anchor: SIMD2<Int16>(100, 200),
                                             properties: [:])

        XCTAssertEqual(profile.identity(feature: feature, text: "Moscow", kind: "place"),
                       .providerFeature(providerID: "mapbox",
                                        layerName: "place_label",
                                        featureID: 42))
    }

    func testMapboxProfileBuildsTileLocalIdentityWhenFeatureIDIsAbsent() {
        let profile = MapboxVectorTileLabelProviderProfile(settings: .default)
        let tile = Tile(x: 10, y: 20, z: 5)
        let anchor = SIMD2<Int16>(100, 200)
        let feature = VectorTileLabelFeature(providerID: "mapbox",
                                             tile: tile,
                                             layerName: "poi_label",
                                             featureID: nil,
                                             anchor: anchor,
                                             properties: [:])

        XCTAssertEqual(profile.identity(feature: feature, text: "Museum", kind: "poi"),
                       .tileLocal(tile: tile,
                                  layerName: "poi_label",
                                  text: "Museum",
                                  anchor: anchor))
    }

    func testMapboxProfileNormalizedKindTrimsLowercasesAndJoinsLayerClassType() {
        let profile = MapboxVectorTileLabelProviderProfile(settings: .default)

        XCTAssertEqual(profile.normalizedKind(layerName: " POI_Label ",
                                              properties: [
                                                  "class": stringValue(" Cafe "),
                                                  "type": stringValue(" Coffee Shop ")
                                              ]),
                       "poi_label:cafe:coffee shop")
    }

    func testMapboxProfileNormalizedKindSkipsMissingAndEmptyClassType() {
        let profile = MapboxVectorTileLabelProviderProfile(settings: .default)

        XCTAssertEqual(profile.normalizedKind(layerName: " Place_Label ",
                                              properties: [
                                                  "class": stringValue(" "),
                                                  "type": stringValue("")
                                              ]),
                       "place_label")
    }

    func testMapboxProfileIncludesContinentAndOceanNaturalLabelsOnlyAtLowZoom() {
        let profile = MapboxVectorTileLabelProviderProfile(settings: .default)

        XCTAssertTrue(profile.includesBasePointLabel(layerName: "natural_label",
                                                     properties: ["class": stringValue("continent")],
                                                     tileZoom: 2,
                                                     sortKey: 1_000))
        XCTAssertFalse(profile.includesBasePointLabel(layerName: "natural_label",
                                                      properties: ["class": stringValue("continent")],
                                                      tileZoom: 3,
                                                      sortKey: 1_000))
        XCTAssertTrue(profile.includesBasePointLabel(layerName: "natural_label",
                                                     properties: ["type": stringValue("ocean")],
                                                     tileZoom: 2,
                                                     sortKey: 1_000))
        XCTAssertFalse(profile.includesBasePointLabel(layerName: "natural_label",
                                                      properties: ["type": stringValue("ocean")],
                                                      tileZoom: 3,
                                                      sortKey: 1_000))
    }

    func testMapboxProfileIncludesCapitalLabelsOnlyInConfiguredZoomRange() {
        let profile = MapboxVectorTileLabelProviderProfile(settings: .default)
        let properties: [String: VectorTile_Tile.Value] = [
            "class": stringValue("settlement"),
            "type": stringValue("city"),
            "capital": boolValue(true)
        ]

        XCTAssertTrue(profile.includesBasePointLabel(layerName: "place_label",
                                                     properties: properties,
                                                     tileZoom: 2,
                                                     sortKey: 1_000))
        XCTAssertFalse(profile.includesBasePointLabel(layerName: "place_label",
                                                      properties: properties,
                                                      tileZoom: 13,
                                                      sortKey: 1_000))
    }

    func testMapboxProfileIncludesPoiLandmarksByMinimumZoomAndThreshold() {
        let profile = MapboxVectorTileLabelProviderProfile(settings: .default)
        let properties: [String: VectorTile_Tile.Value] = ["type": stringValue("museum")]

        XCTAssertFalse(profile.includesBasePointLabel(layerName: "poi_label",
                                                      properties: properties,
                                                      tileZoom: 14,
                                                      sortKey: 1))
        XCTAssertTrue(profile.includesBasePointLabel(layerName: "poi_label",
                                                     properties: properties,
                                                     tileZoom: 15,
                                                     sortKey: 200))
        XCTAssertFalse(profile.includesBasePointLabel(layerName: "poi_label",
                                                      properties: properties,
                                                      tileZoom: 15,
                                                      sortKey: 201))
    }

    func testMapboxProfileIncludesRegularPoiByMinimumZoomAndThreshold() {
        let profile = MapboxVectorTileLabelProviderProfile(settings: .default)
        let properties: [String: VectorTile_Tile.Value] = ["type": stringValue("shop")]

        XCTAssertFalse(profile.includesBasePointLabel(layerName: "poi_label",
                                                      properties: properties,
                                                      tileZoom: 12,
                                                      sortKey: 1))
        XCTAssertTrue(profile.includesBasePointLabel(layerName: "poi_label",
                                                     properties: properties,
                                                     tileZoom: 13,
                                                     sortKey: 60))
        XCTAssertFalse(profile.includesBasePointLabel(layerName: "poi_label",
                                                      properties: properties,
                                                      tileZoom: 13,
                                                      sortKey: 61))
    }

    func testMapboxProfileIncludesAirportLabelsByMinimumZoomAndThreshold() {
        let profile = MapboxVectorTileLabelProviderProfile(settings: .default)

        XCTAssertFalse(profile.includesBasePointLabel(layerName: "airport_label",
                                                      properties: [:],
                                                      tileZoom: 7,
                                                      sortKey: 1))
        XCTAssertTrue(profile.includesBasePointLabel(layerName: "airport_label",
                                                     properties: [:],
                                                     tileZoom: 8,
                                                     sortKey: 55))
        XCTAssertFalse(profile.includesBasePointLabel(layerName: "airport_label",
                                                      properties: [:],
                                                      tileZoom: 8,
                                                      sortKey: 56))
    }

    func testMapboxProfileIncludesNaturalRiverLikeLabelsByMinimumZoomAndThreshold() {
        let profile = MapboxVectorTileLabelProviderProfile(settings: .default)
        let properties: [String: VectorTile_Tile.Value] = ["class": stringValue("river")]

        XCTAssertFalse(profile.includesBasePointLabel(layerName: "natural_label",
                                                      properties: properties,
                                                      tileZoom: 8,
                                                      sortKey: 1))
        XCTAssertTrue(profile.includesBasePointLabel(layerName: "natural_label",
                                                     properties: properties,
                                                     tileZoom: 9,
                                                     sortKey: 70))
        XCTAssertFalse(profile.includesBasePointLabel(layerName: "natural_label",
                                                      properties: properties,
                                                      tileZoom: 9,
                                                      sortKey: 71))
    }

    func testMapboxProfileIncludesCityLabelsByZoomRangeAndThreshold() {
        let profile = MapboxVectorTileLabelProviderProfile(settings: .default)
        let properties: [String: VectorTile_Tile.Value] = ["type": stringValue("city")]

        XCTAssertFalse(profile.includesBasePointLabel(layerName: "place_label",
                                                      properties: properties,
                                                      tileZoom: 1,
                                                      sortKey: 1))
        XCTAssertTrue(profile.includesBasePointLabel(layerName: "place_label",
                                                     properties: properties,
                                                     tileZoom: 2,
                                                     sortKey: 80))
        XCTAssertFalse(profile.includesBasePointLabel(layerName: "place_label",
                                                      properties: properties,
                                                      tileZoom: 2,
                                                      sortKey: 81))
        XCTAssertFalse(profile.includesBasePointLabel(layerName: "place_label",
                                                      properties: properties,
                                                      tileZoom: 13,
                                                      sortKey: 1))
    }

    func testMapboxProfileKeepsZoomThreeCityLabelsSparse() {
        let profile = MapboxVectorTileLabelProviderProfile(settings: .default)
        let cityProperties: [String: VectorTile_Tile.Value] = ["type": stringValue("city")]
        let capitalProperties: [String: VectorTile_Tile.Value] = [
            "type": stringValue("city"),
            "capital": boolValue(true)
        ]

        XCTAssertTrue(profile.includesBasePointLabel(layerName: "place_label",
                                                     properties: capitalProperties,
                                                     tileZoom: 3,
                                                     sortKey: 1_000))
        XCTAssertTrue(profile.includesBasePointLabel(layerName: "place_label",
                                                     properties: cityProperties,
                                                     tileZoom: 3,
                                                     sortKey: 70))
        XCTAssertFalse(profile.includesBasePointLabel(layerName: "place_label",
                                                      properties: cityProperties,
                                                      tileZoom: 3,
                                                      sortKey: 90))
    }

    func testMapboxProfileIncludesDistrictLabelsByMinimumZoomAndThreshold() {
        let profile = MapboxVectorTileLabelProviderProfile(settings: .default)
        let properties: [String: VectorTile_Tile.Value] = ["type": stringValue("suburb")]

        XCTAssertFalse(profile.includesBasePointLabel(layerName: "place_label",
                                                      properties: properties,
                                                      tileZoom: 8,
                                                      sortKey: 1))
        XCTAssertTrue(profile.includesBasePointLabel(layerName: "place_label",
                                                     properties: properties,
                                                     tileZoom: 9,
                                                     sortKey: 150))
        XCTAssertFalse(profile.includesBasePointLabel(layerName: "place_label",
                                                      properties: properties,
                                                      tileZoom: 9,
                                                      sortKey: 171))
    }

    func testMapboxProfileIncludesCommonDistrictLabelsAtZoomNine() {
        let profile = MapboxVectorTileLabelProviderProfile(settings: .default)
        let properties: [String: VectorTile_Tile.Value] = ["type": stringValue("suburb")]

        XCTAssertTrue(profile.includesBasePointLabel(layerName: "place_label",
                                                     properties: properties,
                                                     tileZoom: 9,
                                                     sortKey: 166))
    }

    func testMapboxProfileIncludesSmallSettlementsByZoomRangeAndThreshold() {
        let profile = MapboxVectorTileLabelProviderProfile(settings: .default)
        let properties: [String: VectorTile_Tile.Value] = ["type": stringValue("town")]

        XCTAssertTrue(profile.includesBasePointLabel(layerName: "place_label",
                                                     properties: properties,
                                                     tileZoom: 9,
                                                     sortKey: 160))
        XCTAssertTrue(profile.includesBasePointLabel(layerName: "place_label",
                                                     properties: properties,
                                                     tileZoom: 10,
                                                     sortKey: 180))
        XCTAssertFalse(profile.includesBasePointLabel(layerName: "place_label",
                                                      properties: properties,
                                                      tileZoom: 10,
                                                      sortKey: 181))
        XCTAssertFalse(profile.includesBasePointLabel(layerName: "place_label",
                                                      properties: properties,
                                                      tileZoom: 13,
                                                      sortKey: 1))
    }

    func testOpenStreetMapProfileKeepsOnlyCountriesAndMajorCitiesAtZoomThree() {
        let profile = OpenStreetMapVectorTileLabelProviderProfile(settings: .default)

        XCTAssertTrue(profile.includesBasePointLabel(layerName: "boundary_labels",
                                                     properties: [
                                                        "name": stringValue("Russia"),
                                                        "admin_level": intValue(2)
                                                     ],
                                                     tileZoom: 3,
                                                     sortKey: 1))
        XCTAssertFalse(profile.includesBasePointLabel(layerName: "boundary_labels",
                                                      properties: [
                                                        "name": stringValue("Moscow Oblast"),
                                                        "admin_level": intValue(4)
                                                      ],
                                                      tileZoom: 3,
                                                      sortKey: 1))
        XCTAssertTrue(profile.includesBasePointLabel(layerName: "boundary_labels",
                                                     properties: [
                                                        "name": stringValue("Moscow Oblast"),
                                                        "admin_level": intValue(4)
                                                     ],
                                                     tileZoom: 4,
                                                     sortKey: 1))
        XCTAssertTrue(profile.includesBasePointLabel(layerName: "place_labels",
                                                     properties: [
                                                        "name": stringValue("Moscow"),
                                                        "kind": stringValue("city"),
                                                        "population": intValue(13_000_000)
                                                     ],
                                                     tileZoom: 3,
                                                     sortKey: 1))
        XCTAssertFalse(profile.includesBasePointLabel(layerName: "place_labels",
                                                      properties: [
                                                        "name": stringValue("Regional City"),
                                                        "kind": stringValue("city"),
                                                        "population": intValue(600_000)
                                                      ],
                                                      tileZoom: 3,
                                                      sortKey: 1))
        XCTAssertFalse(profile.includesBasePointLabel(layerName: "place_labels",
                                                      properties: [
                                                        "name": stringValue("Large Town"),
                                                        "kind": stringValue("town"),
                                                        "population": intValue(2_000_000)
                                                      ],
                                                      tileZoom: 3,
                                                      sortKey: 1))
        XCTAssertFalse(profile.includesBasePointLabel(layerName: "water_polygons_labels",
                                                      properties: ["name": stringValue("Local Lake")],
                                                      tileZoom: 3,
                                                      sortKey: 1))
    }

    func testOpenStreetMapProfilePrioritizesLargePlaceLabels() {
        let profile = OpenStreetMapVectorTileLabelProviderProfile(settings: .default)

        let capitalSortKey = profile.sortKey(properties: [
            "kind": stringValue("city"),
            "population": intValue(13_000_000),
            "capital": intValue(2)
        ])
        let regionalCitySortKey = profile.sortKey(properties: [
            "kind": stringValue("city"),
            "population": intValue(600_000)
        ])
        let townSortKey = profile.sortKey(properties: [
            "kind": stringValue("town"),
            "population": intValue(80_000)
        ])
        let unrankedSortKey = profile.sortKey(properties: ["kind": stringValue("village")])

        XCTAssertLessThan(capitalSortKey, regionalCitySortKey)
        XCTAssertLessThan(regionalCitySortKey, townSortKey)
        XCTAssertLessThan(townSortKey, unrankedSortKey)
    }

    func testDecisionEngineBuildsTextLabelCompatibleDecision() {
        let style = LabelTextStyle(key: 30,
                                   fillColor: SIMD3<Float>(0.1, 0.2, 0.3),
                                   strokeColor: SIMD3<Float>(1, 1, 1),
                                   strokeWidthPx: 2,
                                   sizePx: 24,
                                   weight: .thin)
        let profile = MapboxVectorTileLabelProviderProfile(settings: .default)
        let engine = VectorTileLabelDecisionEngine(profile: profile,
                                                   textResolver: VectorTileLabelTextResolver(glyphCoverage: .legacyAtlasForTests))
        let feature = VectorTileLabelFeature(providerID: "mapbox",
                                             tile: Tile(x: 123, y: 456, z: 10),
                                             layerName: "place_label",
                                             featureID: 7,
                                             anchor: SIMD2<Int16>(2048, 2048),
                                             properties: [
                                                "name_en": stringValue("Moscow"),
                                                "type": stringValue("city")
                                             ])

        let decision = engine.makePointLabelDecision(feature: feature,
                                                     style: style,
                                                     poiIcon: nil)

        XCTAssertEqual(decision?.text, "Moscow")
        XCTAssertEqual(decision?.priority.collisionRank,
                       profile.collisionRank(layerName: "place_label",
                                             sortKey: decision?.priority.visibilityRank ?? -1))
        XCTAssertEqual(decision?.identity,
                       .providerFeature(providerID: "mapbox",
                                        layerName: "place_label",
                                        featureID: 7))
        XCTAssertEqual(decision?.style.key, style.key)
        XCTAssertEqual(decision?.style.sizePx, style.sizePx)
    }

    func testTextLabelCanUseDecisionRuntimeKey() {
        let style = LabelTextStyle(key: 31,
                                   fillColor: SIMD3<Float>(0.1, 0.2, 0.3),
                                   strokeColor: SIMD3<Float>(1, 1, 1),
                                   strokeWidthPx: 2,
                                   sizePx: 24,
                                   weight: .bold)
        let identity = VectorTileLabelIdentity.tileLocal(tile: Tile(x: 1, y: 2, z: 3),
                                                         layerName: "poi_label",
                                                         text: "Cafe",
                                                         anchor: SIMD2<Int16>(120, 240))

        let label = TileMvtParser.TextLabel(text: "Cafe",
                                            position: SIMD2<Int16>(120, 240),
                                            key: identity.runtimeKey,
                                            sortKey: 50,
                                            collisionPriority: 200_050,
                                            textStyle: style)

        XCTAssertEqual(label.key, identity.runtimeKey)
        XCTAssertEqual(label.sortKey, 50)
        XCTAssertEqual(label.collisionPriority, 200_050)
    }

    func testLabelLanguageNormalizesBCP47CodeForProviderFields() {
        let language = ImmersiveMapSettings.LabelLanguage("PT-BR")

        XCTAssertEqual(language.code, "pt-br")
        XCTAssertEqual(language.providerFieldSuffix, "pt")
        XCTAssertEqual(language.preparedTileCacheNamespaceKey, "pt-br")
    }

    func testLabelLanguageNormalizesUnderscoreBCP47Code() {
        let language = ImmersiveMapSettings.LabelLanguage("pt_BR")

        XCTAssertEqual(language.code, "pt-br")
    }

    func testLabelLanguagePreparedTileCacheNamespaceKeyIsPathSafe() {
        let language = ImmersiveMapSettings.LabelLanguage("EN/../../secret:token")
        let namespaceKey = language.preparedTileCacheNamespaceKey

        XCTAssertFalse(namespaceKey.contains("/"))
        XCTAssertFalse(namespaceKey.contains(":"))
        XCTAssertFalse(namespaceKey.contains(".."))
    }

    func testKnownLabelLanguagesRemainAvailable() {
        XCTAssertEqual(ImmersiveMapSettings.LabelLanguage.english.code, "en")
        XCTAssertEqual(ImmersiveMapSettings.LabelLanguage.russian.code, "ru")
        XCTAssertEqual(ImmersiveMapSettings.LabelLanguage.french.code, "fr")
        XCTAssertEqual(ImmersiveMapSettings.LabelLanguage.german.code, "de")
        XCTAssertEqual(ImmersiveMapSettings.LabelLanguage.spanish.code, "es")
        XCTAssertEqual(ImmersiveMapSettings.LabelLanguage.italian.code, "it")
        XCTAssertEqual(ImmersiveMapSettings.LabelLanguage.portuguese.code, "pt")
        XCTAssertEqual(ImmersiveMapSettings.LabelLanguage.turkish.code, "tr")
    }

    private func stringValue(_ value: String) -> VectorTile_Tile.Value {
        var tileValue = VectorTile_Tile.Value()
        tileValue.stringValue = value
        return tileValue
    }

    private func uintValue(_ value: UInt64) -> VectorTile_Tile.Value {
        var tileValue = VectorTile_Tile.Value()
        tileValue.uintValue = value
        return tileValue
    }

    private func intValue(_ value: Int64) -> VectorTile_Tile.Value {
        var tileValue = VectorTile_Tile.Value()
        tileValue.intValue = value
        return tileValue
    }

    private func sintValue(_ value: Int64) -> VectorTile_Tile.Value {
        var tileValue = VectorTile_Tile.Value()
        tileValue.sintValue = value
        return tileValue
    }

    private func floatValue(_ value: Float) -> VectorTile_Tile.Value {
        var tileValue = VectorTile_Tile.Value()
        tileValue.floatValue = value
        return tileValue
    }

    private func doubleValue(_ value: Double) -> VectorTile_Tile.Value {
        var tileValue = VectorTile_Tile.Value()
        tileValue.doubleValue = value
        return tileValue
    }

    private func boolValue(_ value: Bool) -> VectorTile_Tile.Value {
        var tileValue = VectorTile_Tile.Value()
        tileValue.boolValue = value
        return tileValue
    }
}
