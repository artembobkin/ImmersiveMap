// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

//
//  VisibleTileIndexAllocator.swift
//  ImmersiveMap
//

import Foundation

/// Shared tile-index allocator for a tile-tracked rebuild frame.
/// Keeps projection tiles and provides stable indices by `VisibleTile`.
final class VisibleTileIndexAllocator {
    private(set) var indexedTiles: [VisibleTile]
    private var tileIndexByTile: [VisibleTile: UInt32]

    init(indexedTiles tiles: [VisibleTile]) {
        let expectedTileCount = tiles.count
        self.indexedTiles = []
        self.indexedTiles.reserveCapacity(expectedTileCount)
        tileIndexByTile = Dictionary(minimumCapacity: expectedTileCount)
        precomputeTileIndices(tiles)
    }

    @inline(__always)
    func tileIndex(for tile: VisibleTile) -> UInt32 {
        if let precomputedIndex = tileIndexByTile[tile] {
            return precomputedIndex
        }
        preconditionFailure("VisibleTileIndexAllocator: tile index is missing for \(tile). Unexpected tiles are not allowed.")
    }

    private func precomputeTileIndices(_ tiles: [VisibleTile]) {
        for visibleTile in tiles {
            if tileIndexByTile[visibleTile] != nil {
                continue
            }
            tileIndexByTile[visibleTile] = checkedNextTileIndex()
            indexedTiles.append(visibleTile)
        }
    }

    @inline(__always)
    private func checkedNextTileIndex() -> UInt32 {
        assert(indexedTiles.count <= Int(UInt32.max),
               "Visible tile index overflow.")
        return UInt32(indexedTiles.count)
    }
}
