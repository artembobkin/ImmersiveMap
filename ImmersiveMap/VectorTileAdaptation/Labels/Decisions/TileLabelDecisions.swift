// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Mvt

/// The label policy a tile parse asks questions of: which text a road or a
/// point feature is labelled with, which icon a POI takes, how a labelled
/// point is identified and ranked, and which spelling of a name the map's
/// language and the text atlas allow.
///
/// Assembled once by the caller from the schema reading (which properties
/// carry text, which layers are house numbers), the style (how labels are
/// identified), the glyph coverage of the text atlas and the language
/// settings, then handed
/// to `TileMvtParser`, which holds nothing of the policy itself: the parser
/// decodes geometry and asks, this answers. Every answer is pure, so one
/// value serves every parse of a map.
struct TileLabelDecisions {
    /// The style the label identities are minted for.
    let styleID: String

    private let labelTextKeys: [String]
    private let houseNumberTextKeys: [String]
    private let houseNumberLayers: Set<String>
    private let usesFeatureIdentity: Bool
    private let languagePreferences: VectorTileLabelLanguagePreferences
    private let glyphCoverage: VectorTileLabelGlyphCoverage
    private let textResolver: VectorTileLabelTextResolver
    private let poiSpriteResolver = PoiSpriteResolver()

    init(schema: any ImmersiveMapTileSchema,
         style: any ImmersiveMapVectorTileStyle,
         glyphCoverage: VectorTileLabelGlyphCoverage,
         language: ImmersiveMapSettings.LabelLanguage,
         fallbackPolicy: ImmersiveMapSettings.LabelFallbackPolicy) {
        self.styleID = style.styleID
        self.labelTextKeys = schema.labelTextKeys
        self.houseNumberTextKeys = schema.houseNumberTextKeys
        self.houseNumberLayers = Set(schema.houseNumberLayers.map { $0.lowercased() })
        self.usesFeatureIdentity = style.labelsUseFeatureIdentity
        self.languagePreferences = VectorTileLabelLanguagePreferences.from(settingsLanguage: language,
                                                                           fallbackPolicy: fallbackPolicy)
        self.glyphCoverage = glyphCoverage
        self.textResolver = VectorTileLabelTextResolver(glyphCoverage: glyphCoverage)
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

    /// How a point feature the style labels is labelled: its text (the
    /// house number on a house-number layer, the name in the map's language
    /// elsewhere), its identity across tiles, and the priorities the style
    /// gave it. Nil when the feature carries no text the atlas can render.
    func pointLabelDecision(feature: VectorTileLabelFeature,
                            style: FeatureStyle,
                            poiIcon: PoiSpriteIcon?) -> VectorTileLabelDecision? {
        guard let textStyle = style.labelTextStyle else {
            return nil
        }
        let text: String?
        if houseNumberLayers.contains(feature.layerName.lowercased()) {
            text = textResolver.resolveHouseNumber(properties: feature.properties,
                                                   additionalKeys: houseNumberTextKeys)
        } else {
            text = textResolver.resolveText(properties: feature.properties,
                                            preferences: languagePreferences,
                                            additionalKeys: labelTextKeys)
        }
        guard let resolvedText = text else {
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
                                       priority: VectorTileLabelPriority(visibilityRank: style.labelRank,
                                                                         collisionRank: style.labelCollisionRank,
                                                                         deduplicationRank: style.labelRank,
                                                                         drawRank: style.labelRank),
                                       placement: .centered,
                                       style: textStyle,
                                       poiIcon: poiIcon)
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
