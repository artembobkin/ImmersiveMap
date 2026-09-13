// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

enum VectorTileLabelIdentity: Equatable {
    case styleFeature(styleID: String, layerName: String, featureID: UInt64)
    case semantic(styleID: String, kind: String, text: String, worldBucket: SIMD2<Int32>)
    case tileLocal(tile: Tile, layerName: String, text: String, anchor: SIMD2<Int16>)

    var participatesInCrossTileDeduplication: Bool {
        switch self {
        case .styleFeature, .semantic:
            return true
        case .tileLocal:
            return false
        }
    }

    var runtimeKey: UInt64 {
        var hasher = VectorTileLabelStableHasher()
        switch self {
        case let .styleFeature(styleID, layerName, featureID):
            hasher.combine("providerFeature")
            hasher.combine(styleID)
            hasher.combine(layerName)
            hasher.combine(featureID)
        case let .semantic(styleID, kind, text, worldBucket):
            hasher.combine("semantic")
            hasher.combine(styleID)
            hasher.combine(kind)
            hasher.combine(text)
            hasher.combine(Int(worldBucket.x))
            hasher.combine(Int(worldBucket.y))
        case let .tileLocal(tile, layerName, text, anchor):
            hasher.combine("tileLocal")
            hasher.combine(tile.x)
            hasher.combine(tile.y)
            hasher.combine(tile.z)
            hasher.combine(layerName)
            hasher.combine(text)
            hasher.combine(anchor.x)
            hasher.combine(anchor.y)
        }
        return hasher.finalize()
    }
}
