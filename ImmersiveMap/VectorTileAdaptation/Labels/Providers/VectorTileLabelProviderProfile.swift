// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt

protocol VectorTileLabelProviderProfile {
    var providerID: String { get }
    var languagePreferences: VectorTileLabelLanguagePreferences { get }
    var labelTextKeys: [String] { get }
    var houseNumberTextKeys: [String] { get }

    func sortKey(properties: [String: MvtValue]) -> Int
    func collisionRank(layerName: String, sortKey: Int) -> Int
    func includesBasePointLabel(layerName: String,
                                properties: [String: MvtValue],
                                tileZoom: Int,
                                sortKey: Int) -> Bool
    func identity(feature: VectorTileLabelFeature, text: String, kind: String) -> VectorTileLabelIdentity
    func normalizedKind(layerName: String, properties: [String: MvtValue]) -> String
    func isHouseNumberLayer(_ layerName: String) -> Bool
    func detailCategory(layerName: String) -> VectorTileLabelDetailCategory
}

extension VectorTileLabelProviderProfile {
    var labelTextKeys: [String] {
        []
    }

    var houseNumberTextKeys: [String] {
        []
    }

    /// Tier category by layer name: covers the OpenMapTiles (`poi`) and
    /// Mapbox Streets (`poi_label`) schemas, all other point layers count as
    /// anchor labels.
    func detailCategory(layerName: String) -> VectorTileLabelDetailCategory {
        if isHouseNumberLayer(layerName) {
            return .housenumber
        }
        if layerName.lowercased().contains("poi") {
            return .poi
        }
        return .anchor
    }
}
