// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

struct VectorTileLabelDecisionEngine {
    private let profile: VectorTileLabelProviderProfile
    private let textResolver: VectorTileLabelTextResolver

    init(profile: VectorTileLabelProviderProfile,
         textResolver: VectorTileLabelTextResolver) {
        self.profile = profile
        self.textResolver = textResolver
    }

    func makePointLabelDecision(feature: VectorTileLabelFeature,
                                style: LabelTextStyle,
                                poiIcon: PoiSpriteIcon?) -> VectorTileLabelDecision? {
        let text: String?
        if profile.isHouseNumberLayer(feature.layerName) {
            text = textResolver.resolveHouseNumber(properties: feature.properties,
                                                   additionalKeys: profile.houseNumberTextKeys)
        } else {
            text = textResolver.resolveText(properties: feature.properties,
                                            preferences: profile.languagePreferences,
                                            additionalKeys: profile.labelTextKeys)
        }

        guard let resolvedText = text else {
            return nil
        }

        let sortKey = profile.sortKey(properties: feature.properties)
        guard profile.includesBasePointLabel(layerName: feature.layerName,
                                             properties: feature.properties,
                                             tileZoom: feature.tile.z,
                                             sortKey: sortKey) else {
            return nil
        }

        let collisionRank = profile.collisionRank(layerName: feature.layerName,
                                                  sortKey: sortKey)
        let kind = profile.normalizedKind(layerName: feature.layerName,
                                          properties: feature.properties)
        let identity = profile.identity(feature: feature,
                                        text: resolvedText,
                                        kind: kind)
        return VectorTileLabelDecision(text: resolvedText,
                                       identity: identity,
                                       priority: VectorTileLabelPriority(visibilityRank: sortKey,
                                                                         collisionRank: collisionRank,
                                                                         deduplicationRank: sortKey,
                                                                         drawRank: sortKey),
                                       placement: .centered,
                                       style: style,
                                       poiIcon: poiIcon)
    }
}
