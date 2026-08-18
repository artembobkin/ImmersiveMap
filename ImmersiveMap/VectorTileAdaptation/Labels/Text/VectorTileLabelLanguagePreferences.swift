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
        var fallbackChain: [Candidate] = []

        // A language is looked up under both spellings a source can carry:
        // OpenMapTiles flattens OSM's `name:xx` tags to `name_xx`, while a
        // schema passing OSM tags through unchanged keeps the colon. A tile
        // never carries both with different values, so the order between the
        // two does not matter; missing keys just fall through.
        func appendLanguage(_ suffix: String, kind: Candidate.Kind) {
            fallbackChain.append(Candidate(fieldName: "name_\(suffix)", kind: kind))
            fallbackChain.append(Candidate(fieldName: "name:\(suffix)", kind: kind))
        }

        if settingsLanguage == .english {
            appendLanguage("en", kind: .english)
            fallbackChain.append(Candidate(fieldName: "name", kind: .native))
        } else {
            appendLanguage(settingsLanguage.providerFieldSuffix, kind: .preferred)
            switch fallbackPolicy {
            case .international:
                appendLanguage("en", kind: .english)
                fallbackChain.append(Candidate(fieldName: "name", kind: .native))
            case .localFirst:
                fallbackChain.append(Candidate(fieldName: "name", kind: .native))
                appendLanguage("en", kind: .english)
            }
        }

        return VectorTileLabelLanguagePreferences(fallbackChain: fallbackChain,
                                                  selectedLanguage: settingsLanguage,
                                                  fallbackPolicy: fallbackPolicy)
    }
}
