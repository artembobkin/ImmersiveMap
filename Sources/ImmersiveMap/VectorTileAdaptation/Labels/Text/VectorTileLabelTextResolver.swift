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
                     preferences: VectorTileLabelLanguagePreferences,
                     uppercased: Bool = false) -> String? {
        for candidate in preferences.fallbackChain {
            var text = candidate.languageCode.map { label.namesByLanguage[$0] } ?? label.name
            switch candidate.kind {
            case .romanizedNative:
                text = text.flatMap(preferences.romanizer.romanize)
            case .nativeInMapScript:
                text = text.flatMap { preferences.mapScript?.writes($0) == true ? $0 : nil }
            case .preferred, .native, .english:
                break
            }
            if uppercased {
                text = text?.uppercased()
            }
            guard let text, text.isEmpty == false, glyphCoverage.canRender(text) else {
                continue
            }
            return text
        }
        return nil
    }
}
