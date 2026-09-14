// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// Picks the spelling of a name the map shows: the first of the language
/// chain's candidates the feature carries and the text atlas can render.
struct VectorTileLabelTextResolver {
    private let glyphCoverage: VectorTileLabelGlyphCoverage

    init(glyphCoverage: VectorTileLabelGlyphCoverage) {
        self.glyphCoverage = glyphCoverage
    }

    func resolveText(label: ImmersiveMapLabelFacts,
                     preferences: VectorTileLabelLanguagePreferences) -> String? {
        for candidate in preferences.fallbackChain {
            let text = candidate.languageCode.map { label.namesByLanguage[$0] } ?? label.name
            guard let text, text.isEmpty == false, glyphCoverage.canRender(text) else {
                continue
            }
            return text
        }
        return nil
    }

    func resolveHouseNumber(label: ImmersiveMapLabelFacts) -> String? {
        guard let number = label.houseNumber, number.isEmpty == false, glyphCoverage.canRender(number) else {
            return nil
        }
        return number
    }
}
