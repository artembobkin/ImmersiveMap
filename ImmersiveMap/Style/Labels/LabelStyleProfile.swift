// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Mvt

/// The label half of a style: which properties of the schema carry a
/// label's text, rank and kind, and how a feature's label is ranked and
/// identified. The `VectorTileAdaptation` folder turns these answers into
/// label decisions (text through the language fallback chain and the glyph
/// coverage, stable identities, visibility, collision and draw priority)
/// before anything reaches the tile buffers, the label caches or the draw
/// code. Pure decisions: no Metal, no runtime caches or fade state
/// (`Labels`), no tile fetching, no views.
protocol LabelStyleProfile {
    var styleID: String { get }
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

extension LabelStyleProfile {
    var labelTextKeys: [String] {
        []
    }

    var houseNumberTextKeys: [String] {
        []
    }
}
