// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

protocol VectorTileLabelProviderProfile {
    var providerID: String { get }
    var languagePreferences: VectorTileLabelLanguagePreferences { get }
    var labelTextKeys: [String] { get }
    var houseNumberTextKeys: [String] { get }

    func sortKey(properties: [String: VectorTile_Tile.Value]) -> Int
    func collisionRank(layerName: String, sortKey: Int) -> Int
    func includesBasePointLabel(layerName: String,
                                properties: [String: VectorTile_Tile.Value],
                                tileZoom: Int,
                                sortKey: Int) -> Bool
    func identity(feature: VectorTileLabelFeature, text: String, kind: String) -> VectorTileLabelIdentity
    func normalizedKind(layerName: String, properties: [String: VectorTile_Tile.Value]) -> String
    func isHouseNumberLayer(_ layerName: String) -> Bool
}

extension VectorTileLabelProviderProfile {
    var labelTextKeys: [String] {
        []
    }

    var houseNumberTextKeys: [String] {
        []
    }
}
