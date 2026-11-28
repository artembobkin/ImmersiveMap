// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

/// The levels of detail a model archive holds its models at, the coarsest
/// first. Each level is the tiles of one zoom of the archive: a model is in
/// the tile of that zoom its origin lies in, once per level, so the levels
/// are a pyramid over the same ground and a tile of a coarser level holds
/// the models of the four tiles under it in the next one, made lighter.
///
/// A map shows one level at a time, chosen by the camera's zoom, and asks
/// for the tiles of that level's zoom alone. A baker writes a model into
/// each level it has a mesh for, with the same id, the same origin and the
/// same replaced buildings in every one: the map swaps a tile for the
/// tiles over the same ground and expects the same models there.
///
/// An archive need not hold every level. The zoom range in the archive's
/// header says which it has (`PMTilesWriter` writes it from the tiles), and
/// a map shows the nearest level the archive holds in place of a missing
/// one, so an archive of the `high` level alone draws as it always did.
public enum ModelTileDetail: Int, CaseIterable, Comparable, Sendable {
    /// The lightest models, for the zooms a city is seen whole at.
    case low
    case medium
    /// The models in full.
    case high

    /// The zoom of the archive's tiles that hold the level.
    public var tileZoom: Int {
        switch self {
        case .low: return 12
        case .medium: return 13
        case .high: return 14
        }
    }

    /// The level whose tiles are of `tileZoom`, nil for a zoom no level is at.
    public init?(tileZoom: Int) {
        guard let detail = Self.allCases.first(where: { $0.tileZoom == tileZoom }) else {
            return nil
        }
        self = detail
    }

    public static func < (lhs: ModelTileDetail, rhs: ModelTileDetail) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
