// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  CoverageTargetsHasher.swift
//  ImmersiveMap
//

import Foundation

enum CoverageTargetsHasher {
    static func computeTargetsHash(
        targets: [VisibleTile],
        readyTilesBySource: [Tile: MetalTile?]
    ) -> Int {
        computeTargetsHash(
            targets: targets,
            demandedSourceTiles: targets.map(\.tile),
            readyTilesBySource: readyTilesBySource
        )
    }

    static func computeTargetsHash(
        targets: [VisibleTile],
        demandedSourceTiles: [Tile],
        readyTilesBySource: [Tile: MetalTile?]
    ) -> Int {
        computeTargetsHash(targets: targets,
                                            demandedSourceTiles: demandedSourceTiles) { source in
            if let sourceTile = readyTilesBySource[source] {
                return sourceTile != nil
            }
            return false
        }
    }

    static func computeTargetsHash(
        targets: [VisibleTile],
        isSourceReady: (Tile) -> Bool
    ) -> Int {
        computeTargetsHash(targets: targets,
                                            demandedSourceTiles: targets.map(\.tile),
                                            isSourceReady: isSourceReady)
    }

    static func computeTargetsHash(
        targets: [VisibleTile],
        demandedSourceTiles: [Tile],
        isSourceReady: (Tile) -> Bool
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(targets.count)
        for target in targets {
            hasher.combine(target)
            hasher.combine(isSourceReady(target.tile))
        }

        hasher.combine(demandedSourceTiles.count)
        for sourceTile in demandedSourceTiles {
            hasher.combine(sourceTile)
            hasher.combine(isSourceReady(sourceTile))
        }
        return hasher.finalize()
    }
}
