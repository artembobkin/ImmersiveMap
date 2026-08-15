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
        let identity = VectorTileLabelIdentity.providerFeature(providerID: "example",
                                                               layerName: "place_label",
                                                               featureID: 42)

        XCTAssertTrue(identity.participatesInCrossTileDeduplication)
        XCTAssertEqual(identity.runtimeKey, 8141700374101987561)
        XCTAssertEqual(identity.runtimeKey,
                       VectorTileLabelIdentity.providerFeature(providerID: "example",
                                                               layerName: "place_label",
                                                               featureID: 42).runtimeKey)
    }

    func testSemanticIdentityUsesStableRuntimeKey() {
        let identity = VectorTileLabelIdentity.semantic(providerID: "example",
                                                        kind: "place",
                                                        text: "Moscow",
                                                        worldBucket: SIMD2<Int32>(10, 20))

        XCTAssertTrue(identity.participatesInCrossTileDeduplication)
        XCTAssertEqual(identity.runtimeKey, 2508529565867420114)
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

    func testDecisionEngineBuildsTextLabelCompatibleDecision() {
        let style = LabelTextStyle(key: 30,
                                   fillColor: SIMD3<Float>(0.1, 0.2, 0.3),
                                   strokeColor: SIMD3<Float>(1, 1, 1),
                                   haloEm: 0.15,
                                   sizePoints: 24,
                                   weight: .thin)
        let profile = ImmersiveMapTilesVectorTileLabelProviderProfile(settings: .default)
        let engine = VectorTileLabelDecisionEngine(profile: profile,
                                                   textResolver: VectorTileLabelTextResolver(glyphCoverage: .legacyAtlasForTests))
        let feature = VectorTileLabelFeature(providerID: "immersivemaptiles",
                                             tile: Tile(x: 123, y: 456, z: 10),
                                             layerName: "place",
                                             featureID: 7,
                                             anchor: SIMD2<Int16>(2048, 2048),
                                             properties: [
                                                "name_en": stringValue("Moscow"),
                                                "class": stringValue("city")
                                             ])

        let decision = engine.makePointLabelDecision(feature: feature,
                                                     style: style,
                                                     poiIcon: nil)

        XCTAssertEqual(decision?.text, "Moscow")
        XCTAssertEqual(decision?.priority.collisionRank,
                       profile.collisionRank(layerName: "place",
                                             sortKey: decision?.priority.visibilityRank ?? -1))
        XCTAssertEqual(decision?.identity,
                       .providerFeature(providerID: "immersivemaptiles",
                                        layerName: "place",
                                        featureID: 7))
        XCTAssertEqual(decision?.style.key, style.key)
        XCTAssertEqual(decision?.style.sizePoints, style.sizePoints)
    }

    func testTextLabelCanUseDecisionRuntimeKey() {
        let style = LabelTextStyle(key: 31,
                                   fillColor: SIMD3<Float>(0.1, 0.2, 0.3),
                                   strokeColor: SIMD3<Float>(1, 1, 1),
                                   haloEm: 0.15,
                                   sizePoints: 24,
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
}
