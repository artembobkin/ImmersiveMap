// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Mvt

/// The label policy a tile parse asks questions of: which spelling a road
/// or a point feature is labelled with, how a labelled point is identified
/// and ranked, and which spelling of a name the map's language and the
/// text atlas allow.
///
/// Assembled once by the caller from the style (how labels are
/// identified), the glyph coverage of the text atlas and the language
/// settings, then handed to `TileMvtParser`, which holds nothing of the
/// policy itself: the parser decodes geometry and asks, this answers, from
/// the names the schema reading stated (`ImmersiveMapLabelFacts`). Every
/// answer is pure, so one value serves every parse of a map.
struct TileLabelDecisions {
    /// The style the label identities are minted for.
    let styleID: String

    private let usesFeatureIdentity: Bool
    private let languagePreferences: VectorTileLabelLanguagePreferences
    private let glyphCoverage: VectorTileLabelGlyphCoverage
    private let textResolver: VectorTileLabelTextResolver

    init(style: any ImmersiveMapVectorTileStyle,
         glyphCoverage: VectorTileLabelGlyphCoverage,
         language: ImmersiveMapSettings.LabelLanguage,
         fallbackPolicy: ImmersiveMapSettings.LabelFallbackPolicy) {
        self.styleID = style.styleID
        self.usesFeatureIdentity = style.labelsUseFeatureIdentity
        self.languagePreferences = VectorTileLabelLanguagePreferences.from(settingsLanguage: language,
                                                                           fallbackPolicy: fallbackPolicy)
        self.glyphCoverage = glyphCoverage
        self.textResolver = VectorTileLabelTextResolver(glyphCoverage: glyphCoverage)
    }

    /// The name a road line is labelled with, in the map's language with its
    /// fallback chain, or nil when the feature carries none the atlas can
    /// render.
    func roadLabelText(label: ImmersiveMapLabelFacts?) -> String? {
        guard let label else { return nil }
        return textResolver.resolveText(label: label, preferences: languagePreferences)
    }

    /// How a point feature the style labels is labelled: its text (the
    /// name in the map's language), its identity across tiles, and the priorities
    /// and the sprite the style gave it. Nil when the feature carries no
    /// text the atlas can render.
    func pointLabelDecision(feature: VectorTileLabelFeature,
                            label: ImmersiveMapLabelFacts,
                            style: PointLabelStyle) -> VectorTileLabelDecision? {
        guard let resolvedText = textResolver.resolveText(label: label, preferences: languagePreferences) else {
            return nil
        }
        let identity: VectorTileLabelIdentity
        if usesFeatureIdentity, let featureID = feature.featureID {
            identity = .styleFeature(styleID: styleID, layerName: feature.layerName, featureID: featureID)
        } else {
            identity = .tileLocal(tile: feature.tile,
                                  layerName: feature.layerName,
                                  text: resolvedText,
                                  anchor: feature.anchor)
        }
        return VectorTileLabelDecision(text: resolvedText,
                                       identity: identity,
                                       priority: VectorTileLabelPriority(visibilityRank: style.rank,
                                                                         collisionRank: style.collisionRank,
                                                                         deduplicationRank: style.rank,
                                                                         drawRank: style.rank),
                                       placement: .centered,
                                       style: style.text,
                                       poiIcon: style.icon)
    }

    /// The spelling of a name the map shows, chosen from names keyed by
    /// language code (`"en"`, `"ru"`, ...) plus `"native"` for the local
    /// one, walking the same fallback chain a feature's names would, and
    /// skipping any the atlas cannot render. English is the last resort.
    /// For the labels the parser synthesizes itself, which carry no facts
    /// to resolve from.
    func localizedName(from names: [String: String]) -> String? {
        for candidate in languagePreferences.fallbackChain {
            let code = candidate.languageCode ?? "native"
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
