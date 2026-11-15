// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Mvt
import simd

struct VectorTileLabelFeature {
    let styleID: String
    let tile: Tile
    let layerName: String
    let featureID: UInt64?
    let anchor: SIMD2<Int16>
}
