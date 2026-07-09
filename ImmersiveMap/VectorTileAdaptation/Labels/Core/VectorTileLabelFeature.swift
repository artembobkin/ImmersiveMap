// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

struct VectorTileLabelFeature {
    let providerID: String
    let tile: Tile
    let layerName: String
    let featureID: UInt64?
    let anchor: SIMD2<Int16>
    let properties: [String: VectorTile_Tile.Value]
}
