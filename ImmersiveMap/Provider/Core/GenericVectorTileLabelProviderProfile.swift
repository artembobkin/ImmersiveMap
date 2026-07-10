// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

struct GenericVectorTileLabelProviderProfile: VectorTileLabelProviderProfile {
    let providerID: String
    let languagePreferences: VectorTileLabelLanguagePreferences
    let profile: ImmersiveMapVectorTileLabelProfile

    init(providerID: String,
         settings: ImmersiveMapSettings,
         profile: ImmersiveMapVectorTileLabelProfile = .generic) {
        self.providerID = providerID
        self.profile = profile
        self.languagePreferences = VectorTileLabelLanguagePreferences.from(
            settingsLanguage: settings.labels.language,
            fallbackPolicy: settings.labels.fallbackPolicy
        )
    }

    var labelTextKeys: [String] {
        profile.textKeys
    }

    var houseNumberTextKeys: [String] {
        profile.houseNumberTextKeys
    }

    func sortKey(properties: [String: VectorTile_Tile.Value]) -> Int {
        for key in profile.rankKeys {
            guard let value = properties[key], let rank = parseIntValue(value) else {
                continue
            }
            return max(0, rank)
        }
        return 0
    }

    func collisionRank(layerName: String, sortKey: Int) -> Int {
        sortKey
    }

    func includesBasePointLabel(layerName: String,
                                properties: [String: VectorTile_Tile.Value],
                                tileZoom: Int,
                                sortKey: Int) -> Bool {
        guard profile.includesPointLabelLayer(layerName) else {
            return false
        }
        if isHouseNumberLayer(layerName) {
            return hasRenderableText(properties: properties, keys: ["house_num"] + profile.houseNumberTextKeys)
        }
        return hasRenderableText(
            properties: properties,
            keys: languagePreferences.fallbackChain.map(\.fieldName) + profile.textKeys
        )
    }

    func identity(feature: VectorTileLabelFeature, text: String, kind: String) -> VectorTileLabelIdentity {
        if profile.usesFeatureIdentity, let featureID = feature.featureID {
            return .providerFeature(providerID: providerID,
                                    layerName: feature.layerName,
                                    featureID: featureID)
        }
        return .tileLocal(tile: feature.tile,
                          layerName: feature.layerName,
                          text: text,
                          anchor: feature.anchor)
    }

    func normalizedKind(layerName: String, properties: [String: VectorTile_Tile.Value]) -> String {
        ([layerName] + profile.kindKeys.compactMap { properties[$0]?.stringValue })
            .compactMap { value in
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard normalized.isEmpty == false else {
                    return nil
                }
                return normalized
            }
            .joined(separator: ":")
    }

    func isHouseNumberLayer(_ layerName: String) -> Bool {
        profile.houseNumberLayers.contains(layerName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private func hasRenderableText(properties: [String: VectorTile_Tile.Value], keys: [String]) -> Bool {
        var seen = Set<String>()
        for key in keys where seen.insert(key).inserted {
            guard properties[key]?.stringValue.isEmpty == false else {
                continue
            }
            return true
        }
        return false
    }

    private func parseIntValue(_ value: VectorTile_Tile.Value) -> Int? {
        if value.hasIntValue {
            return Int(value.intValue)
        }
        if value.hasUintValue {
            return Int(value.uintValue)
        }
        if value.hasSintValue {
            return Int(value.sintValue)
        }
        if value.hasDoubleValue {
            return Int(value.doubleValue)
        }
        if value.hasFloatValue {
            return Int(value.floatValue)
        }
        if value.hasStringValue {
            return Int(value.stringValue)
        }
        return nil
    }
}
