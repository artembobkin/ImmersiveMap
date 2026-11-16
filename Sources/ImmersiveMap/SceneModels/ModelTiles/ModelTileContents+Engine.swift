// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import ModelTileFormat

// The model tile's format is a module of its own (`ModelTileFormat`), which
// knows nothing of the engine. Here its values become the engine's: the
// tile a decoded model tile is of, and the OSM element a model replaces.

extension ModelTileContents {
    /// The map tile the models' origins lie in.
    var tile: Tile {
        Tile(x: x, y: y, z: zoom)
    }
}

extension ImmersiveMapOSMElement {
    /// The element a model tile names.
    init(_ element: ModelTileElement) {
        switch element {
        case .node(let id): self = .node(id)
        case .way(let id): self = .way(id)
        case .relation(let id): self = .relation(id)
        }
    }
}
