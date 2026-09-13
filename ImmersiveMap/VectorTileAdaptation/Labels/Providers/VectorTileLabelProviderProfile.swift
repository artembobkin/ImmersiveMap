// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt

/// The `VectorTileAdaptation` folder: where provider-specific vector tile
/// schemas become provider-neutral label decisions, before anything reaches
/// the tile buffers, the label caches or the draw code. It normalizes layer
/// names, classes, ranks and name fields, chooses label text through the
/// language fallback chain and the glyph coverage, mints stable label
/// identities, and decides visibility, collision and draw priority. Pure
/// decisions: no Metal, no runtime caches or fade state (`Labels`), no tile
/// fetching, no views, and no public API while the model is unstable.
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
}

extension VectorTileLabelProviderProfile {
    var labelTextKeys: [String] {
        []
    }

    var houseNumberTextKeys: [String] {
        []
    }
}
