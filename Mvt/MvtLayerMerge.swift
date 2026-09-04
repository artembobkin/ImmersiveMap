// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

extension MvtDecodedTile {
    /// Merges every layer named `sourceName` into the first layer whose name
    /// is in `targetNames`: the source's features are appended to the
    /// target, their tag indices re-based onto the target's key and value
    /// tables, which grow by the source's. Geometry is untouched, both layers
    /// point into the same payload. The target keeps its position among the
    /// layers and the merged sources disappear.
    ///
    /// A source with a different extent than the target (its coordinates
    /// would not line up) stays a layer of its own, and a tile with no target
    /// layer is returned as it is. What the names mean is the caller's: this
    /// is a wire-level operation on a decoded tile, not a reading of the
    /// schema.
    package func merging(layersNamed sourceName: String,
                         intoFirstLayerNamed targetNames: Set<String>) -> MvtDecodedTile {
        guard layers.contains(where: { $0.name == sourceName }),
              let targetIndex = layers.firstIndex(where: { targetNames.contains($0.name) }) else {
            return self
        }
        var target = layers[targetIndex]
        var merged: [MvtDecodedLayer] = []
        merged.reserveCapacity(layers.count)
        // The target's place among the layers that survive, which is not
        // its index when a merged source came before it.
        var targetPosition = 0
        for (index, layer) in layers.enumerated() {
            if index == targetIndex {
                targetPosition = merged.count
                continue
            }
            guard layer.name == sourceName, layer.extent == target.extent else {
                merged.append(layer)
                continue
            }
            Self.append(layer, to: &target, data: sourceData)
        }
        merged.insert(target, at: targetPosition)
        return MvtDecodedTile(layers: merged, sourceData: sourceData)
    }

    private static func append(_ layer: MvtDecodedLayer, to target: inout MvtDecodedLayer, data: Data) {
        let keyOffset = UInt32(target.keys.count)
        let valueOffset = UInt32(target.values.count)
        target.keys.append(contentsOf: layer.keys)
        target.values.append(contentsOf: layer.values)
        target.features.reserveCapacity(target.features.count + layer.features.count)
        for var feature in layer.features {
            let tags = feature.tags.materializedValues(data: data)
            if tags.isEmpty {
                feature.tags = .empty
            } else {
                var rebased: [UInt32] = []
                rebased.reserveCapacity(tags.count)
                for (position, index) in tags.enumerated() {
                    rebased.append(index &+ (position.isMultiple(of: 2) ? keyOffset : valueOffset))
                }
                feature.tags = .values(rebased)
            }
            target.features.append(feature)
        }
    }
}
