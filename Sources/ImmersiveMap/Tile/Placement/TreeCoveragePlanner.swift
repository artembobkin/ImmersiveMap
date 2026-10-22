// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

/// The flat map's trees follow the building coverage
/// (`BuildingCoveragePlanner`): a tile that draws its buildings draws its
/// trees, whole, in its own square, so the trees stand through a change
/// of zoom as the buildings do and never draw twice. What is the trees'
/// own is the camera zoom they draw from (`TreeSettings.minimumZoom`),
/// read per frame.
enum TreeCoveragePlanner {
    /// The coarsest tile zoom that carries trees: the tile zoom the
    /// buildings draw from (`BuildingCoveragePlanner.minimumDrawZoom`),
    /// since the coverage draws a coarser tile standing in for its loading
    /// children, or placed by a far ring, in place of them, and a tile
    /// without trees standing in for tiles with them would open a hole in
    /// a wood with every move of the camera. The lattice is fixed in the
    /// world (`TreeScatter`), so a tile and its children stand the same
    /// trees. The parser places no tree in a coarser tile
    /// (`TileParseOptions`). Nil with the trees off.
    static func minimumSourceZoom(settings: ImmersiveMapSettings) -> Int? {
        guard settings.scene.trees.isEnabled else { return nil }
        return BuildingCoveragePlanner.minimumDrawZoom(settings: settings)
    }
}
