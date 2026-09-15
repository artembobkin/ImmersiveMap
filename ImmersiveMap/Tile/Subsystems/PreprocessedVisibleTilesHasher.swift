// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  PreprocessedVisibleTilesHasher.swift
//  ImmersiveMap
//

import Foundation

enum PreprocessedVisibleTilesHasher {
    static func computePreprocessedVisibleTilesHash(
        preprocessedVisibleTiles: [VisibleTile],
        readyTilesBySource: [Tile: MetalTile?]
    ) -> Int {
        computePreprocessedVisibleTilesHash(
            preprocessedVisibleTiles: preprocessedVisibleTiles,
            demandedSourceTiles: preprocessedVisibleTiles.map(\.tile),
            readyTilesBySource: readyTilesBySource
        )
    }

    static func computePreprocessedVisibleTilesHash(
        preprocessedVisibleTiles: [VisibleTile],
        demandedSourceTiles: [Tile],
        readyTilesBySource: [Tile: MetalTile?]
    ) -> Int {
        computePreprocessedVisibleTilesHash(preprocessedVisibleTiles: preprocessedVisibleTiles,
                                            demandedSourceTiles: demandedSourceTiles) { source in
            if let sourceTile = readyTilesBySource[source] {
                return sourceTile != nil
            }
            return false
        }
    }

    static func computePreprocessedVisibleTilesHash(
        preprocessedVisibleTiles: [VisibleTile],
        isSourceReady: (Tile) -> Bool
    ) -> Int {
        computePreprocessedVisibleTilesHash(preprocessedVisibleTiles: preprocessedVisibleTiles,
                                            demandedSourceTiles: preprocessedVisibleTiles.map(\.tile),
                                            isSourceReady: isSourceReady)
    }

    static func computePreprocessedVisibleTilesHash(
        preprocessedVisibleTiles: [VisibleTile],
        demandedSourceTiles: [Tile],
        isSourceReady: (Tile) -> Bool
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(preprocessedVisibleTiles.count)
        for preprocessedVisibleTile in preprocessedVisibleTiles {
            hasher.combine(preprocessedVisibleTile)
            hasher.combine(isSourceReady(preprocessedVisibleTile.tile))
        }

        hasher.combine(demandedSourceTiles.count)
        for sourceTile in demandedSourceTiles {
            hasher.combine(sourceTile)
            hasher.combine(isSourceReady(sourceTile))
        }
        return hasher.finalize()
    }
}
