// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Mvt

/// Folds the streetscape layer into the road layer of a decoded tile.
///
/// The tile service ships the measured streetscape (the carriageway
/// surfaces reconstructed from the road graph and the paint on them) as a
/// second, streetscape-only archive whose tiles carry one layer,
/// `streetscape`. The loader appends that tile's bytes to the map tile's, so
/// the decoder sees both layers, but the parser's road machinery works one
/// layer at a time: the surfaces clip the ribbons of the roads that enter
/// them, a measured crossing suppresses the crossing read off the same
/// road's attributes, the tunnel roofs are found among the surfaces. All of
/// that needs the streetscape and the roads in one feature list, which is
/// what this makes: the streetscape's features are appended to the road
/// layer, their tag indices re-based onto the road layer's key and value
/// tables. Geometry is untouched: both layers point into the same payload.
///
/// A streetscape layer with no road layer to join, or with a different
/// extent (its coordinates would not line up), stays a layer of its own and
/// still takes the road path, because `TileMvtParser` counts the name as a
/// road layer.
enum MvtRoadLayerFold {
    static let streetscapeLayerName = "streetscape"

    private static func isRoadLayer(_ name: String) -> Bool {
        name == "road" || name == "transportation"
    }

    static func foldingStreetscapeLayers(_ tile: MvtDecodedTile) -> MvtDecodedTile {
        guard tile.layers.contains(where: { $0.name == streetscapeLayerName }),
              let roadIndex = tile.layers.firstIndex(where: { isRoadLayer($0.name) }) else {
            return tile
        }
        var road = tile.layers[roadIndex]
        var layers: [MvtDecodedLayer] = []
        layers.reserveCapacity(tile.layers.count)
        for (index, layer) in tile.layers.enumerated() {
            if index == roadIndex {
                continue
            }
            guard layer.name == streetscapeLayerName, layer.extent == road.extent else {
                layers.append(layer)
                continue
            }
            append(layer, to: &road, data: tile.sourceData)
        }
        layers.insert(road, at: min(roadIndex, layers.count))
        return MvtDecodedTile(layers: layers, sourceData: tile.sourceData)
    }

    private static func append(_ layer: MvtDecodedLayer, to road: inout MvtDecodedLayer, data: Data) {
        let keyOffset = UInt32(road.keys.count)
        let valueOffset = UInt32(road.values.count)
        road.keys.append(contentsOf: layer.keys)
        road.values.append(contentsOf: layer.values)
        road.features.reserveCapacity(road.features.count + layer.features.count)
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
            road.features.append(feature)
        }
    }
}
