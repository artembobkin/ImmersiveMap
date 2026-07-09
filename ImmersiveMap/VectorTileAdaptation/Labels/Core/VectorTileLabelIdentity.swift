// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import simd

enum VectorTileLabelIdentity: Equatable {
    case providerFeature(providerID: String, layerName: String, featureID: UInt64)
    case semantic(providerID: String, kind: String, text: String, worldBucket: SIMD2<Int32>)
    case tileLocal(tile: Tile, layerName: String, text: String, anchor: SIMD2<Int16>)

    var participatesInCrossTileDeduplication: Bool {
        switch self {
        case .providerFeature, .semantic:
            return true
        case .tileLocal:
            return false
        }
    }

    var runtimeKey: UInt64 {
        var hasher = VectorTileLabelStableHasher()
        switch self {
        case let .providerFeature(providerID, layerName, featureID):
            hasher.combine("providerFeature")
            hasher.combine(providerID)
            hasher.combine(layerName)
            hasher.combine(featureID)
        case let .semantic(providerID, kind, text, worldBucket):
            hasher.combine("semantic")
            hasher.combine(providerID)
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
