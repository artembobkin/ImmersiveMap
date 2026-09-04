// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import XCTest

/// A language is looked up under both spellings a source can carry:
/// OpenMapTiles flattens OSM's `name:xx` tags to `name_xx`, while a schema
/// passing OSM tags through unchanged keeps the colon. Reading only the
/// underscore form left an English-configured map showing native `name`
/// values ("América", "Afrika;أفريقيا") over tiles that carry `name:en`.
final class VectorTileLabelLanguagePreferencesTests: XCTestCase {
    private func stringValue(_ string: String) -> MvtValue {
        .string(string)
    }

    func testEnglishChainTriesBothSpellingsBeforeTheNativeName() {
        let chain = VectorTileLabelLanguagePreferences.from(settingsLanguage: .english)
            .fallbackChain.map(\.fieldName)
        XCTAssertEqual(chain, ["name_en", "name:en", "name"])
    }

    func testNonEnglishInternationalChainKeepsEnglishBeforeNative() {
        let chain = VectorTileLabelLanguagePreferences.from(settingsLanguage: .russian,
                                                            fallbackPolicy: .international)
            .fallbackChain.map(\.fieldName)
        XCTAssertEqual(chain, ["name_ru", "name:ru", "name_en", "name:en", "name"])
    }

    func testNonEnglishLocalFirstChainKeepsNativeBeforeEnglish() {
        let chain = VectorTileLabelLanguagePreferences.from(settingsLanguage: .russian,
                                                            fallbackPolicy: .localFirst)
            .fallbackChain.map(\.fieldName)
        XCTAssertEqual(chain, ["name_ru", "name:ru", "name", "name_en", "name:en"])
    }

    func testResolverReadsTheColonFormWhenTheSourcePassesOSMTagsThrough() {
        let resolver = VectorTileLabelTextResolver(glyphCoverage: .legacyAtlasForTests)
        let text = resolver.resolveText(
            properties: ["name": stringValue("América"), "name:en": stringValue("Americas")],
            preferences: .from(settingsLanguage: .english)
        )
        XCTAssertEqual(text, "Americas")
    }

    func testResolverStillReadsTheOpenMapTilesForm() {
        let resolver = VectorTileLabelTextResolver(glyphCoverage: .legacyAtlasForTests)
        let text = resolver.resolveText(
            properties: ["name": stringValue("Deutschland"), "name_en": stringValue("Germany")],
            preferences: .from(settingsLanguage: .english)
        )
        XCTAssertEqual(text, "Germany")
    }

    func testNativeNameStaysTheLastResort() {
        let resolver = VectorTileLabelTextResolver(glyphCoverage: .legacyAtlasForTests)
        let text = resolver.resolveText(
            properties: ["name": stringValue("Norge")],
            preferences: .from(settingsLanguage: .english)
        )
        XCTAssertEqual(text, "Norge")
    }
}
