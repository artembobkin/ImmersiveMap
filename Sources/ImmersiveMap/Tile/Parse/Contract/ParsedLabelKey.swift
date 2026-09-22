// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The identity of a parsed label, an FNV-1a style hash: the layer and the
/// feature id where the tile ships one, otherwise the layer, the text and
/// the geometry. The same feature keys the same across parses, which is
/// what the runtime label cache fades by.
enum ParsedLabelKey {
    static func makePointLabelKey(text: String,
                                  anchor: SIMD2<Int16>,
                                  featureId: UInt64,
                                  hasFeatureId: Bool,
                                  layerName: String) -> UInt64 {
        if hasFeatureId {
            return makeLayerFeatureLabelKey(featureId: featureId, layerName: layerName)
        }
        return makeFallbackLabelKey(text: text,
                                    geometryHash: makePointAnchorHash(anchor),
                                    layerName: layerName)
    }

    static func makeRoadLabelKey(text: String,
                                 path: [SIMD2<Int16>],
                                 featureId: UInt64,
                                 hasFeatureId: Bool,
                                 layerName: String) -> UInt64 {
        if hasFeatureId {
            return makeLayerFeatureLabelKey(featureId: featureId, layerName: layerName)
        }
        return makeFallbackLabelKey(text: text,
                                    geometryHash: makeRoadPathHash(path),
                                    layerName: layerName)
    }

    private static func makeLayerFeatureLabelKey(featureId: UInt64, layerName: String) -> UInt64 {
        var hash = labelKeySeed
        mixUtf8(into: &hash, string: layerName)
        mix(into: &hash, value: featureId)
        return hash
    }

    private static func makeFallbackLabelKey(text: String,
                                             geometryHash: UInt64,
                                             layerName: String) -> UInt64 {
        var hash = labelKeySeed
        mixUtf8(into: &hash, string: layerName)
        mixUtf8(into: &hash, string: text)
        mix(into: &hash, value: geometryHash)
        return hash
    }

    private static func makePointAnchorHash(_ anchor: SIMD2<Int16>) -> UInt64 {
        var hash = labelKeySeed
        mix(into: &hash, value: packedInt16Pair(anchor))
        return hash
    }

    private static func makeRoadPathHash(_ path: [SIMD2<Int16>]) -> UInt64 {
        var hash = labelKeySeed
        mix(into: &hash, value: UInt64(path.count))
        for point in path {
            mix(into: &hash, value: packedInt16Pair(point))
        }
        return hash
    }

    private static func mixUtf8(into hash: inout UInt64, string: String) {
        for byte in string.utf8 {
            mix(into: &hash, value: UInt64(byte))
        }
    }

    private static func mix(into hash: inout UInt64, value: UInt64) {
        hash ^= value
        hash &*= labelKeyPrime
    }

    private static func packedInt16Pair(_ point: SIMD2<Int16>) -> UInt64 {
        let x = UInt32(UInt16(bitPattern: point.x))
        let y = UInt32(UInt16(bitPattern: point.y))
        let packed = (x << 16) | y
        return UInt64(packed)
    }

    private static let labelKeySeed: UInt64 = 1469598103934665603
    private static let labelKeyPrime: UInt64 = 1099511628211
}
