// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

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
/// what the merge makes. The merge itself is the decoder's
/// (`MvtDecodedTile.merging(layersNamed:intoFirstLayerNamed:)`); what is
/// here is the schema: which layer is the streetscape and which layers are
/// roads.
///
/// A streetscape layer with no road layer to join, or with a different
/// extent, stays a layer of its own and still takes the road path, because
/// `TileMvtParser` counts the name as a road layer.
enum MvtRoadLayerFold {
    static let streetscapeLayerName = "streetscape"
    static let roadLayerNames: Set<String> = ["road", "transportation"]

    static func foldingStreetscapeLayers(_ tile: MvtDecodedTile) -> MvtDecodedTile {
        tile.merging(layersNamed: streetscapeLayerName, intoFirstLayerNamed: roadLayerNames)
    }
}
