// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  TileProjectionIndexSubsystem.swift
//  ImmersiveMap
//

import Foundation
import Metal

final class TileProjectionIndexSubsystem: RenderSubsystem {
    let name: String = "TileProjectionIndex"

    private let flatTileOriginCalculator: FlatTileOriginCalculator

    private var sourceProjectionTiles: [VisibleTile] = []
    private var tileOriginDataBuffer: MTLBuffer?
    private var tileIndexAllocator: VisibleTileIndexAllocator = VisibleTileIndexAllocator(indexedTiles: [])
    private var sourceProjectionTracker = StagedHashChangeTracker()
    private var requiresAllocatorRebuildAfterReset: Bool = true
    private var sourceIndexVersion: UInt64 = 0

    init(flatTileOriginCalculator: FlatTileOriginCalculator) {
        self.flatTileOriginCalculator = flatTileOriginCalculator
    }

    func update(frameContext: FrameContext) {
        let placeTiles = frameContext.sharedState.placeTileTrackingState.placeTiles
        let nextProjectionTiles = makeSourceProjectionTiles(from: placeTiles)
        let projectionHash = makeProjectionTilesHash(nextProjectionTiles)
        let shouldRebuildAllocator = sourceProjectionTracker.stage(projectionHash) || requiresAllocatorRebuildAfterReset
        if shouldRebuildAllocator {
            sourceProjectionTiles = nextProjectionTiles
            tileIndexAllocator = VisibleTileIndexAllocator(indexedTiles: sourceProjectionTiles)
            requiresAllocatorRebuildAfterReset = false
            sourceIndexVersion &+= 1
            sourceProjectionTracker.commitPending()
        }

        if frameContext.resolvedPresentation.flatProjectionInputsEnabled {
            tileOriginDataBuffer = flatTileOriginCalculator.update(slot: frameContext.frameSlotIndex,
                                                                   tiles: tileIndexAllocator.indexedTiles,
                                                                   flatRenderState: frameContext.resolvedPresentation.flatRenderState)
        } else {
            tileOriginDataBuffer = nil
        }

        frameContext.sharedState.tileProjectionIndexState = TileProjectionIndexState(
            sourceProjectionTiles: sourceProjectionTiles,
            tileIndexAllocator: tileIndexAllocator,
            tileOriginData: flatTileOriginCalculator.currentTileOriginData,
            tileOriginDataBuffer: tileOriginDataBuffer,
            sourceIndexVersion: sourceIndexVersion
        )
    }

    func prepareGPU(frameContext _: FrameContext, resourceRegistry: RenderResourceRegistry) {
        guard let tileOriginDataBuffer else {
            return
        }
        resourceRegistry.setBuffer(tileOriginDataBuffer, named: .tileOriginDataBuffer)
    }

    func encode(layer _: RenderLayer, encoder _: MTLRenderCommandEncoder, frameContext _: FrameContext) {}

    func handleMemoryWarning() {
        sourceProjectionTiles.removeAll(keepingCapacity: false)
        tileIndexAllocator = VisibleTileIndexAllocator(indexedTiles: [])
        requiresAllocatorRebuildAfterReset = true
        tileOriginDataBuffer = nil
        sourceProjectionTracker.invalidate()
        sourceIndexVersion &+= 1
    }

    func evict() {
        sourceProjectionTiles.removeAll(keepingCapacity: false)
        tileIndexAllocator = VisibleTileIndexAllocator(indexedTiles: [])
        requiresAllocatorRebuildAfterReset = true
        tileOriginDataBuffer = nil
        sourceProjectionTracker.invalidate()
        sourceIndexVersion &+= 1
    }

    private func makeSourceProjectionTiles(from placeTiles: [PlaceTile]) -> [VisibleTile] {
        var projectionTiles: [VisibleTile] = []
        projectionTiles.reserveCapacity(placeTiles.count)
        var seenTiles: Set<VisibleTile> = []

        for placeTile in placeTiles {
            let projectionTile = VisibleTile(tile: placeTile.metalTile.tile, loop: placeTile.placeIn.loop)
            if seenTiles.insert(projectionTile).inserted {
                projectionTiles.append(projectionTile)
            }
        }

        return projectionTiles
    }

    private func makeProjectionTilesHash(_ projectionTiles: [VisibleTile]) -> Int {
        var hasher = Hasher()
        hasher.combine(projectionTiles.count)
        for tile in projectionTiles {
            hasher.combine(tile.x)
            hasher.combine(tile.y)
            hasher.combine(tile.z)
            hasher.combine(tile.loop)
        }
        return hasher.finalize()
    }
}
