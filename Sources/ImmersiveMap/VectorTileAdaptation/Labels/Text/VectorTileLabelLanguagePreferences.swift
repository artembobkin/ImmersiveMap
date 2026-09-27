// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// The order the spellings of a name are tried in for the map's language:
/// the preferred language, then English and the local name in the order
/// the fallback policy states. Under the international policy a map in a
/// language written in Latin letters tries the local name romanized before
/// the local name as it is (`VectorTileLabelRomanizer`), so a name in
/// another alphabet shows in the map's. Which fields of a tile carry a language's
/// spelling is the schema reading's business (`ImmersiveMapLabelFacts`);
/// the chain speaks in language codes.
struct VectorTileLabelLanguagePreferences: Equatable {
    struct Candidate: Equatable {
        enum Kind: Equatable {
            case preferred
            case native
            /// The local name in Latin letters.
            case romanizedNative
            case english
        }

        /// The language code the spelling is looked up under, nil for the
        /// local name and the romanized local name.
        let languageCode: String?
        let kind: Kind
    }

    let fallbackChain: [Candidate]
    let selectedLanguage: ImmersiveMapSettings.LabelLanguage
    let fallbackPolicy: ImmersiveMapSettings.LabelFallbackPolicy
    let romanizer: VectorTileLabelRomanizer

    static func from(
        settingsLanguage: ImmersiveMapSettings.LabelLanguage,
        fallbackPolicy: ImmersiveMapSettings.LabelFallbackPolicy = .international
    ) -> VectorTileLabelLanguagePreferences {
        var fallbackChain: [Candidate] = []
        let english = Candidate(languageCode: "en", kind: .english)
        let native = Candidate(languageCode: nil, kind: .native)
        let romanizer = VectorTileLabelRomanizer(targetLanguage: settingsLanguage)
        let internationalNative = romanizer.isEnabled
            ? [Candidate(languageCode: nil, kind: .romanizedNative), native]
            : [native]

        if settingsLanguage == .english {
            fallbackChain = [english] + internationalNative
        } else {
            let preferred = Candidate(languageCode: settingsLanguage.nameFieldSuffix, kind: .preferred)
            switch fallbackPolicy {
            case .international:
                fallbackChain = [preferred, english] + internationalNative
            case .localFirst:
                fallbackChain = [preferred, native, english]
            }
        }

        return VectorTileLabelLanguagePreferences(fallbackChain: fallbackChain,
                                                  selectedLanguage: settingsLanguage,
                                                  fallbackPolicy: fallbackPolicy,
                                                  romanizer: romanizer)
    }
}
