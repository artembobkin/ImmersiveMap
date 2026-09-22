// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// Reads a feature's attributes: the `tags` field is a run of key/value
/// index pairs into the layer's key and value tables, and the result is the
/// dictionary those pairs spell. A dangling trailing key with no value, and
/// a pair whose index points past either table, are dropped and the rest of
/// the feature survives.
///
/// This is the one per-number loop the engine runs over a tile's tags, and
/// it lives in this module on purpose: the varint reader is a module-internal
/// struct, so the generic loop specializes and inlines here, in one module
/// with the reader, instead of calling across the module boundary once per
/// integer.
package enum MvtAttributeDecoder {
    package static func attributes(of feature: MvtDecodedFeature,
                                   in layer: MvtDecodedLayer,
                                   data: Data) -> [String: MvtValue] {
        data.withUnsafeBytes { bytes in
            attributes(of: feature, in: layer, bytes: bytes)
        }
    }

    package static func attributes(of feature: MvtDecodedFeature,
                                   in layer: MvtDecodedLayer,
                                   bytes: UnsafeRawBufferPointer) -> [String: MvtValue] {
        var attributes: [String: MvtValue] = [:]
        switch feature.tags {
        case .empty:
            break
        case .range(let range):
            guard range.lowerBound >= 0, range.upperBound <= bytes.count else { break }
            var reader = MvtVarintUInt32Reader(bytes: bytes, range: range)
            append(reader: &reader, layer: layer, into: &attributes)
        case .values(let values):
            var reader = MvtArrayUInt32Reader(values: values)
            append(reader: &reader, layer: layer, into: &attributes)
        }
        return attributes
    }

    private static func append<Reader: MvtUInt32Reading>(reader: inout Reader,
                                                         layer: MvtDecodedLayer,
                                                         into attributes: inout [String: MvtValue]) {
        while let keyIndex = reader.next() {
            guard let valueIndex = reader.next() else { break }

            guard Int(keyIndex) < layer.keys.count,
                  Int(valueIndex) < layer.values.count else { continue }

            attributes[layer.keys[Int(keyIndex)]] = layer.values[Int(valueIndex)]
        }
    }
}
