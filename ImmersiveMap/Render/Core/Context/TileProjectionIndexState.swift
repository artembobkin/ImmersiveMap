// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  TileProjectionIndexState.swift
//  ImmersiveMap
//

import Metal

struct TileProjectionIndexState {
    static let empty = TileProjectionIndexState(sourceProjectionTiles: [],
                                                tileIndexAllocator: VisibleTileIndexAllocator(indexedTiles: []),
                                                tileOriginData: [],
                                                tileOriginDataBuffer: nil,
                                                sourceIndexVersion: 0)

    let sourceProjectionTiles: [VisibleTile]
    let tileIndexAllocator: VisibleTileIndexAllocator
    let tileOriginData: [FlatTileOriginData]
    let tileOriginDataBuffer: MTLBuffer?
    let sourceIndexVersion: UInt64
}
