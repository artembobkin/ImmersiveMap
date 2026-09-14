// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The order the spellings of a name are tried in for the map's language:
/// the preferred language, then English and the local name in the order
/// the fallback policy states. Which fields of a tile carry a language's
/// spelling is the schema reading's business (`ImmersiveMapLabelFacts`);
/// the chain speaks in language codes.
struct VectorTileLabelLanguagePreferences: Equatable {
    struct Candidate: Equatable {
        enum Kind: Equatable {
            case preferred
            case native
            case english
        }

        /// The language code the spelling is looked up under, nil for the
        /// local name.
        let languageCode: String?
        let kind: Kind
    }

    let fallbackChain: [Candidate]
    let selectedLanguage: ImmersiveMapSettings.LabelLanguage
    let fallbackPolicy: ImmersiveMapSettings.LabelFallbackPolicy

    static func from(
        settingsLanguage: ImmersiveMapSettings.LabelLanguage,
        fallbackPolicy: ImmersiveMapSettings.LabelFallbackPolicy = .international
    ) -> VectorTileLabelLanguagePreferences {
        var fallbackChain: [Candidate] = []
        let english = Candidate(languageCode: "en", kind: .english)
        let native = Candidate(languageCode: nil, kind: .native)

        if settingsLanguage == .english {
            fallbackChain = [english, native]
        } else {
            let preferred = Candidate(languageCode: settingsLanguage.nameFieldSuffix, kind: .preferred)
            switch fallbackPolicy {
            case .international:
                fallbackChain = [preferred, english, native]
            case .localFirst:
                fallbackChain = [preferred, native, english]
            }
        }

        return VectorTileLabelLanguagePreferences(fallbackChain: fallbackChain,
                                                  selectedLanguage: settingsLanguage,
                                                  fallbackPolicy: fallbackPolicy)
    }
}
