// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Mvt

/// The label policy a tile parse asks questions of: which text a road or a
/// point feature is labelled with, which icon a POI takes, whether a point
/// feature is labelled at all and at what priority, and which spelling of a
/// name the map's language and the text atlas allow.
///
/// Assembled once by the caller from the style's label profile, the glyph
/// coverage of the text atlas and the language settings, then handed to
/// `TileMvtParser`, which holds nothing of the policy itself: the parser
/// decodes geometry and asks, this answers. Every answer is pure, so one
/// value serves every parse of a map.
struct TileLabelDecisions {
    /// The style the label identities are minted for.
    let styleID: String

    private let labelTextKeys: [String]
    private let languagePreferences: VectorTileLabelLanguagePreferences
    private let glyphCoverage: VectorTileLabelGlyphCoverage
    private let textResolver: VectorTileLabelTextResolver
    private let decisionEngine: VectorTileLabelDecisionEngine
    private let poiSpriteResolver = PoiSpriteResolver()

    init(profile: any LabelStyleProfile,
         glyphCoverage: VectorTileLabelGlyphCoverage,
         language: ImmersiveMapSettings.LabelLanguage,
         fallbackPolicy: ImmersiveMapSettings.LabelFallbackPolicy) {
        self.styleID = profile.styleID
        self.labelTextKeys = profile.labelTextKeys
        self.languagePreferences = VectorTileLabelLanguagePreferences.from(settingsLanguage: language,
                                                                           fallbackPolicy: fallbackPolicy)
        self.glyphCoverage = glyphCoverage
        let textResolver = VectorTileLabelTextResolver(glyphCoverage: glyphCoverage)
        self.textResolver = textResolver
        self.decisionEngine = VectorTileLabelDecisionEngine(profile: profile, textResolver: textResolver)
    }

    /// The name a road line is labelled with, in the map's language with its
    /// fallback chain, or nil when the feature carries none the atlas can
    /// render.
    func roadLabelText(properties: [String: MvtValue]) -> String? {
        textResolver.resolveText(properties: properties,
                                 preferences: languagePreferences,
                                 additionalKeys: labelTextKeys)
    }

    /// The sprite a POI feature draws beside its text, nil for every other
    /// feature. Decided per feature, once, before its points are walked.
    func poiIcon(attributes: [String: MvtValue], layerName: String) -> PoiSpriteIcon? {
        poiSpriteResolver.resolve(attributes: attributes, layerName: layerName)
    }

    /// Whether and how a point feature is labelled: its text, identity,
    /// priorities and style, or nil when the label profile leaves it out.
    func pointLabelDecision(feature: VectorTileLabelFeature,
                            style: LabelTextStyle,
                            poiIcon: PoiSpriteIcon?) -> VectorTileLabelDecision? {
        decisionEngine.makePointLabelDecision(feature: feature, style: style, poiIcon: poiIcon)
    }

    /// The spelling of a name the map shows, chosen from names keyed by
    /// language code (`"en"`, `"ru"`, ...) plus `"native"` for the local
    /// one, walking the same fallback chain a feature's `name_xx` fields
    /// would, and skipping any the atlas cannot render. English is the last
    /// resort. For the labels the parser synthesizes itself, which carry no
    /// tile properties to resolve from.
    func localizedName(from names: [String: String]) -> String? {
        for candidate in languagePreferences.fallbackChain {
            let code: String
            if candidate.fieldName == "name" {
                code = "native"
            } else {
                // The chain carries both source spellings of a language
                // field (`name_en` and `name:en`); either strips to the
                // same language code here.
                code = candidate.fieldName
                    .replacingOccurrences(of: "name_", with: "")
                    .replacingOccurrences(of: "name:", with: "")
            }

            guard let value = names[code],
                  value.isEmpty == false,
                  glyphCoverage.canRender(value) else {
                continue
            }

            return value
        }

        return names["en"].flatMap { glyphCoverage.canRender($0) ? $0 : nil }
    }
}
