// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

struct VectorTileLabelLanguagePreferences: Equatable {
    struct Candidate: Equatable {
        enum Kind: Equatable {
            case preferred
            case native
            case english
        }

        let fieldName: String
        let kind: Kind
    }

    let fallbackChain: [Candidate]
    let selectedLanguage: ImmersiveMapSettings.LabelLanguage
    let fallbackPolicy: ImmersiveMapSettings.LabelFallbackPolicy

    static func from(
        settingsLanguage: ImmersiveMapSettings.LabelLanguage,
        fallbackPolicy: ImmersiveMapSettings.LabelFallbackPolicy = .international
    ) -> VectorTileLabelLanguagePreferences {
        let preferredFieldName = "name_\(settingsLanguage.providerFieldSuffix)"
        var fallbackChain: [Candidate] = []

        if settingsLanguage == .english {
            fallbackChain.append(Candidate(fieldName: "name_en", kind: .english))
            fallbackChain.append(Candidate(fieldName: "name", kind: .native))
        } else {
            fallbackChain.append(Candidate(fieldName: preferredFieldName, kind: .preferred))
            switch fallbackPolicy {
            case .international:
                fallbackChain.append(Candidate(fieldName: "name_en", kind: .english))
                fallbackChain.append(Candidate(fieldName: "name", kind: .native))
            case .localFirst:
                fallbackChain.append(Candidate(fieldName: "name", kind: .native))
                fallbackChain.append(Candidate(fieldName: "name_en", kind: .english))
            }
        }

        return VectorTileLabelLanguagePreferences(fallbackChain: fallbackChain,
                                                  selectedLanguage: settingsLanguage,
                                                  fallbackPolicy: fallbackPolicy)
    }
}
