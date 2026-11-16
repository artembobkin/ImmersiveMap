// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

/// The OSM element of a building the map draws on its own, as a model tile
/// names it: its kind and its id. In a tile it is one `u64`, the kind in
/// the top four bits (1 node, 2 way, 3 relation) and the id in the rest.
public enum ModelTileElement: Hashable, Sendable {
    case node(UInt64)
    case way(UInt64)
    case relation(UInt64)

    /// The element of a kind as the tile writes it, nil for a kind the
    /// format has none of.
    public init?(kind: UInt64, id: UInt64) {
        switch kind {
        case 1: self = .node(id)
        case 2: self = .way(id)
        case 3: self = .relation(id)
        default: return nil
        }
    }

    /// The kind as the tile writes it.
    public var kind: UInt64 {
        switch self {
        case .node: return 1
        case .way: return 2
        case .relation: return 3
        }
    }

    public var id: UInt64 {
        switch self {
        case .node(let id), .way(let id), .relation(let id): return id
        }
    }

    /// The ids a tile can hold: the bits under the kind.
    public static let idLimit: UInt64 = 1 << ModelTileContents.replacedBuildingKindShift

    /// The element as its entry in the replaced building block.
    var entry: UInt64 {
        kind << ModelTileContents.replacedBuildingKindShift | id
    }
}
