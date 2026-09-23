// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import XCTest

final class TileLabelDecisionsTests: XCTestCase {
    /// The names of a property dictionary as the Protomaps basemap's reading
    /// states them; an empty reading for a feature with no name at all.
    private func label(_ properties: [String: MvtValue]) -> ImmersiveMapLabelFacts {
        ProtomapsBasemapSchema().facts(layerName: "places", properties: properties, tile: Tile(x: 0, y: 0, z: 10)).label
            ?? ImmersiveMapLabelFacts()
    }

    func testRussianPreferencesPreferRussianThenEnglishThenNative() {
        let properties: [String: MvtValue] = [
            "name": stringValue("Москва"),
            "name:en": stringValue("Moscow"),
            "name:ru": stringValue("Москва")
        ]
        let resolver = VectorTileLabelTextResolver(glyphCoverage: .legacyAtlasForTests)
        let preferences = VectorTileLabelLanguagePreferences.from(settingsLanguage: .russian)

        XCTAssertEqual(preferences.selectedLanguage, .russian)
        XCTAssertEqual(preferences.fallbackPolicy, .international)
        XCTAssertEqual(preferences.fallbackChain.map(\.languageCode), ["ru", "en", nil])
        XCTAssertEqual(resolver.resolveText(label: label(properties), preferences: preferences), "Москва")
    }

    func testFrenchPreferencesFallBackToEnglishBeforeNativeWhenPreferredNameIsAbsent() {
        let properties: [String: MvtValue] = [
            "name": stringValue("Москва"),
            "name:en": stringValue("Moscow")
        ]
        let resolver = VectorTileLabelTextResolver(glyphCoverage: .legacyAtlasForTests)
        let preferences = VectorTileLabelLanguagePreferences.from(settingsLanguage: .french)

        XCTAssertEqual(resolver.resolveText(label: label(properties), preferences: preferences), "Moscow")
    }

    func testLocalFirstPolicyFallsBackToNativeBeforeEnglishWhenPreferredNameIsAbsent() {
        let properties: [String: MvtValue] = [
            "name": stringValue("Москва"),
            "name:en": stringValue("Moscow")
        ]
        let resolver = VectorTileLabelTextResolver(glyphCoverage: .legacyAtlasForTests)
        let preferences = VectorTileLabelLanguagePreferences.from(settingsLanguage: .french,
                                                                  fallbackPolicy: .localFirst)

        XCTAssertEqual(preferences.fallbackPolicy, .localFirst)
        XCTAssertEqual(preferences.fallbackChain.map(\.languageCode), ["fr", nil, "en"])
        XCTAssertEqual(resolver.resolveText(label: label(properties), preferences: preferences), "Москва")
    }

    func testRussianPreferencesFallBackToNativeCyrillicWhenRussianAndEnglishNamesAreAbsent() {
        let properties: [String: MvtValue] = [
            "name": stringValue("Москва")
        ]
        let resolver = VectorTileLabelTextResolver(glyphCoverage: .legacyAtlasForTests)
        let preferences = VectorTileLabelLanguagePreferences.from(settingsLanguage: .russian)

        XCTAssertEqual(resolver.resolveText(label: label(properties), preferences: preferences), "Москва")
    }

    func testEnglishPreferencesPreferEnglishThenNative() {
        let properties: [String: MvtValue] = [
            "name": stringValue("Moscow Native"),
            "name:en": stringValue("Moscow EN"),
            "name:ru": stringValue("Москва")
        ]
        let resolver = VectorTileLabelTextResolver(glyphCoverage: .legacyAtlasForTests)
        let preferences = VectorTileLabelLanguagePreferences.from(settingsLanguage: .english)

        XCTAssertEqual(preferences.selectedLanguage, .english)
        XCTAssertEqual(preferences.fallbackChain.map(\.languageCode), ["en", nil])
        XCTAssertEqual(resolver.resolveText(label: label(properties), preferences: preferences), "Moscow EN")
    }

    func testFrenchPreferencesPreferNameFrThenEnglish() {
        let properties: [String: MvtValue] = [
            "name": stringValue("Paris Native"),
            "name:en": stringValue("Paris EN"),
            "name:fr": stringValue("Paris FR")
        ]
        let resolver = VectorTileLabelTextResolver(glyphCoverage: .legacyAtlasForTests)
        let preferences = VectorTileLabelLanguagePreferences.from(settingsLanguage: .french)

        XCTAssertEqual(preferences.fallbackChain.map(\.languageCode), ["fr", "en", nil])
        XCTAssertEqual(resolver.resolveText(label: label(properties), preferences: preferences), "Paris FR")
    }

    func testSharedResolverCoversRoadLabelFieldSelection() {
        let properties: [String: MvtValue] = [
            "name": stringValue("Rue Native"),
            "name:en": stringValue("Rivoli Street"),
            "name:fr": stringValue("Rue de Rivoli")
        ]
        let resolver = VectorTileLabelTextResolver(glyphCoverage: .legacyAtlasForTests)
        let preferences = VectorTileLabelLanguagePreferences.from(settingsLanguage: .french)

        XCTAssertEqual(resolver.resolveText(label: label(properties), preferences: preferences), "Rue de Rivoli")
    }

    func testGermanPreferencesFallbackToEnglishWhenPreferredFieldIsMissing() {
        let properties: [String: MvtValue] = [
            "name:en": stringValue("Munich EN")
        ]
        let resolver = VectorTileLabelTextResolver(glyphCoverage: .legacyAtlasForTests)
        let preferences = VectorTileLabelLanguagePreferences.from(settingsLanguage: .german)

        XCTAssertEqual(resolver.resolveText(label: label(properties), preferences: preferences), "Munich EN")
    }

    func testEnglishPreferencesFallBackToNativeLatinWhenEnglishNameIsAbsent() {
        let properties: [String: MvtValue] = [
            "name": stringValue("Moscow"),
            "name:ru": stringValue("Москва")
        ]
        let resolver = VectorTileLabelTextResolver(glyphCoverage: .legacyAtlasForTests)
        let preferences = VectorTileLabelLanguagePreferences.from(settingsLanguage: .english)

        XCTAssertEqual(resolver.resolveText(label: label(properties), preferences: preferences), "Moscow")
    }

    func testEnglishPreferencesFallBackToNativeCyrillicWhenEnglishNameIsAbsent() {
        let properties: [String: MvtValue] = [
            "name": stringValue("Москва"),
            "name:ru": stringValue("Москва")
        ]
        let resolver = VectorTileLabelTextResolver(glyphCoverage: .legacyAtlasForTests)
        let preferences = VectorTileLabelLanguagePreferences.from(settingsLanguage: .english)

        XCTAssertEqual(resolver.resolveText(label: label(properties), preferences: preferences), "Москва")
    }

    func testUnsupportedGlyphCoverageRejectsText() {
        let properties: [String: MvtValue] = [
            "name": stringValue("東京")
        ]
        let resolver = VectorTileLabelTextResolver(glyphCoverage: .legacyAtlasForTests)
        let preferences = VectorTileLabelLanguagePreferences.from(settingsLanguage: .english)

        XCTAssertNil(resolver.resolveText(label: label(properties), preferences: preferences))
    }

    func testStyleFeatureIdentityParticipatesInCrossTileDeduplication() {
        let identity = VectorTileLabelIdentity.styleFeature(styleID: "example",
                                                               layerName: "place_label",
                                                               featureID: 42)

        XCTAssertTrue(identity.participatesInCrossTileDeduplication)
        XCTAssertEqual(identity.runtimeKey, 8141700374101987561)
        XCTAssertEqual(identity.runtimeKey,
                       VectorTileLabelIdentity.styleFeature(styleID: "example",
                                                               layerName: "place_label",
                                                               featureID: 42).runtimeKey)
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

    func testTheDecisionsBuildATextLabelCompatibleDecision() throws {
        let style = ProtomapsBasemapDefaultMapStyle()
        let decisions = TileLabelDecisions(style: style,
                                           glyphCoverage: .legacyAtlasForTests,
                                           language: .english,
                                           fallbackPolicy: .international)
        let tile = Tile(x: 123, y: 456, z: 10)
        let properties: [String: MvtValue] = [
            "name:en": stringValue("Moscow"),
            "kind": stringValue("locality"),
            "kind_detail": stringValue("city"),
            "population_rank": .int(15)
        ]
        let featureStyle = style.makeStyle(data: DetFeatureStyleData(layerName: "places",
                                                                     properties: properties,
                                                                     tile: tile,
                                                                     geometryType: .point))
        let feature = VectorTileLabelFeature(styleID: "protomaps",
                                             tile: tile,
                                             layerName: "places",
                                             featureID: 7,
                                             anchor: SIMD2<Int16>(2048, 2048))
        let label = try XCTUnwrap(ProtomapsBasemapSchema().facts(layerName: "places", properties: properties, tile: tile).label)

        let decision = decisions.pointLabelDecision(feature: feature,
                                                    label: label,
                                                    style: featureStyle.pointLabelStyle!)

        XCTAssertEqual(decision?.text, "Moscow")
        // A population rank of 15 out of 18, a city: (18 - 15) * 10 + 2.
        XCTAssertEqual(decision?.priority.visibilityRank, 32, "The rank is the style's reading of the tile")
        XCTAssertEqual(decision?.priority.collisionRank, 32, "A place collides at its own rank")
        XCTAssertEqual(decision?.identity,
                       .styleFeature(styleID: "protomaps",
                                     layerName: "places",
                                     featureID: 7))
        XCTAssertEqual(decision?.style.key, featureStyle.pointLabelStyle?.text.key)
        XCTAssertEqual(decision?.style.sizePoints, featureStyle.pointLabelStyle?.text.sizePoints)
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

        let label = ParsedTextLabel(text: "Cafe",
                                            position: SIMD2<Int16>(120, 240),
                                            key: identity.runtimeKey,
                                            sortKey: 50,
                                            collisionPriority: 200_050,
                                            textStyle: style)

        XCTAssertEqual(label.key, identity.runtimeKey)
        XCTAssertEqual(label.sortKey, 50)
        XCTAssertEqual(label.collisionPriority, 200_050)
    }

    func testLabelLanguageNormalizesBCP47CodeForNameFields() {
        let language = ImmersiveMapSettings.LabelLanguage("PT-BR")

        XCTAssertEqual(language.code, "pt-br")
        XCTAssertEqual(language.nameFieldSuffix, "pt")
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

    private func stringValue(_ value: String) -> MvtValue {
        .string(value)
    }
}
