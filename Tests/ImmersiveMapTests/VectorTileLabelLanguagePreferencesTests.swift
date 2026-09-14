// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Mvt
import XCTest

/// The chain speaks in language codes; which fields carry a language's
/// spelling is the schema reading's business. The OpenStreetMap reading
/// takes both spellings a source can carry: OpenMapTiles flattens OSM's
/// `name:xx` tags to `name_xx`, while a schema passing OSM tags through
/// unchanged keeps the colon. Reading only the underscore form left an
/// English-configured map showing native `name` values ("América",
/// "Afrika;أفريقيا") over tiles that carry `name:en`.
final class VectorTileLabelLanguagePreferencesTests: XCTestCase {
    private func stringValue(_ string: String) -> MvtValue {
        .string(string)
    }

    private func label(_ properties: [String: MvtValue]) -> ImmersiveMapLabelFacts {
        ImmersiveMapLabelFacts.openStreetMap(ImmersiveMapFeatureProperties(values: properties)) ?? ImmersiveMapLabelFacts()
    }

    func testEnglishChainTriesEnglishBeforeTheNativeName() {
        let chain = VectorTileLabelLanguagePreferences.from(settingsLanguage: .english)
            .fallbackChain.map(\.languageCode)
        XCTAssertEqual(chain, ["en", nil])
    }

    func testNonEnglishInternationalChainKeepsEnglishBeforeNative() {
        let chain = VectorTileLabelLanguagePreferences.from(settingsLanguage: .russian,
                                                            fallbackPolicy: .international)
            .fallbackChain.map(\.languageCode)
        XCTAssertEqual(chain, ["ru", "en", nil])
    }

    func testNonEnglishLocalFirstChainKeepsNativeBeforeEnglish() {
        let chain = VectorTileLabelLanguagePreferences.from(settingsLanguage: .russian,
                                                            fallbackPolicy: .localFirst)
            .fallbackChain.map(\.languageCode)
        XCTAssertEqual(chain, ["ru", nil, "en"])
    }

    func testResolverReadsTheColonFormWhenTheSourcePassesOSMTagsThrough() {
        let resolver = VectorTileLabelTextResolver(glyphCoverage: .legacyAtlasForTests)
        let text = resolver.resolveText(
            label: label(["name": stringValue("América"), "name:en": stringValue("Americas")]),
            preferences: .from(settingsLanguage: .english)
        )
        XCTAssertEqual(text, "Americas")
    }

    func testResolverStillReadsTheOpenMapTilesForm() {
        let resolver = VectorTileLabelTextResolver(glyphCoverage: .legacyAtlasForTests)
        let text = resolver.resolveText(
            label: label(["name": stringValue("Deutschland"), "name_en": stringValue("Germany")]),
            preferences: .from(settingsLanguage: .english)
        )
        XCTAssertEqual(text, "Germany")
    }

    func testNativeNameStaysTheLastResort() {
        let resolver = VectorTileLabelTextResolver(glyphCoverage: .legacyAtlasForTests)
        let text = resolver.resolveText(
            label: label(["name": stringValue("Norge")]),
            preferences: .from(settingsLanguage: .english)
        )
        XCTAssertEqual(text, "Norge")
    }
}
