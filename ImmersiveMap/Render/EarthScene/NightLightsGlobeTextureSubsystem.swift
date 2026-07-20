// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal

final class NightLightsGlobeTextureSubsystem: RenderSubsystem {
    let name: String = "NightLights"

    private let tileSetStore: NightLightsTileSetStore
    private let tileCache: NightLightsTileCache
    private let atlasTexture: NightLightsAtlasTexture

    private var previousRequiredTiles: [Tile]?
    private var previousReadyTiles: [Tile]?
    private var atlasState: NightLightsAtlasState = .empty

    init(tileSetStore: NightLightsTileSetStore,
         tileCache: NightLightsTileCache,
         atlasTexture: NightLightsAtlasTexture) {
        self.tileSetStore = tileSetStore
        self.tileCache = tileCache
        self.atlasTexture = atlasTexture
    }

    static func requiredNightLightTiles(for visibleTiles: [Tile],
                                        tileSet: NightLightsTileSet) -> [Tile] {
        let mappedTiles = visibleTiles.compactMap { tileSet.mapping(for: $0)?.tile }
        return Array(Set(mappedTiles)).sorted {
            if $0.z != $1.z {
                return $0.z < $1.z
            }
            if $0.y != $1.y {
                return $0.y < $1.y
            }
            return $0.x < $1.x
        }
    }

    static func renderableRequiredNightLightTiles(for visibleTiles: [Tile],
                                                  tileSet: NightLightsTileSet) -> [Tile] {
        var seenTiles = Set<Tile>()
        var requiredTiles: [Tile] = []
        requiredTiles.reserveCapacity(min(visibleTiles.count,
                                          NightLightsAtlasSurfaceBinding.maxEntryCount))

        for visibleTile in visibleTiles {
            guard let tile = tileSet.mapping(for: visibleTile)?.tile,
                  seenTiles.insert(tile).inserted else {
                continue
            }
            requiredTiles.append(tile)
            if requiredTiles.count == NightLightsAtlasSurfaceBinding.maxEntryCount {
                break
            }
        }

        return requiredTiles
    }

    func update(frameContext _: FrameContext) {}

    func prepareGPU(frameContext: FrameContext, resourceRegistry _: RenderResourceRegistry) {
        guard frameContext.renderSurfaceMode == .spherical,
              frameContext.earthSceneUniform.isEnabled != 0,
              frameContext.earthSceneUniform.nightLightsEnabled != 0,
              let tileSet = tileSetStore.tileSet else {
            publishEmptyState(frameContext: frameContext)
            return
        }

        let visibleTiles = frameContext.sharedState.tilePlacementState
            .tileAtlasPlaceTilesContext
            .tilePlacements
            .map(\.placeIn.tile)
        let requiredTiles = Self.renderableRequiredNightLightTiles(for: visibleTiles, tileSet: tileSet)
        tileCache.prefetchTiles(requiredTiles)
        let tileData = Self.resolveAvailableTileData(requiredTiles: requiredTiles,
                                                     minZoom: tileSet.metadata.minZoom) { tile in
            tileCache.tileData(for: tile)
        }
        let readyTiles = tileData.map(\.tile)

        guard requiredTiles != previousRequiredTiles || readyTiles != previousReadyTiles else {
            frameContext.sharedState.nightLightsAtlasState = atlasState
            return
        }

        atlasState = atlasTexture.update(tiles: tileData)
        previousRequiredTiles = requiredTiles
        previousReadyTiles = readyTiles
        frameContext.sharedState.nightLightsAtlasState = atlasState
    }

    /// Resolves each required tile to renderable data, preferring the exact tile and
    /// otherwise falling back to the deepest already-loaded ancestor. Ancestors cover
    /// the required (drawn) tile geometrically, so the shader keeps showing the coarser
    /// lights through a zoom change until the exact tiles finish loading, instead of
    /// blinking off. Deduped so several children sharing one ancestor add a single entry.
    static func resolveAvailableTileData(requiredTiles: [Tile],
                                         minZoom: Int,
                                         tileData: (Tile) -> NightLightsTileData?) -> [NightLightsTileData] {
        var seenTiles = Set<Tile>()
        var resolved: [NightLightsTileData] = []
        resolved.reserveCapacity(requiredTiles.count)

        for requiredTile in requiredTiles {
            guard let bestTileData = bestAvailableTileData(for: requiredTile,
                                                           minZoom: minZoom,
                                                           tileData: tileData),
                  seenTiles.insert(bestTileData.tile).inserted else {
                continue
            }
            resolved.append(bestTileData)
        }

        return resolved
    }

    static func bestAvailableTileData(for tile: Tile,
                                      minZoom: Int,
                                      tileData: (Tile) -> NightLightsTileData?) -> NightLightsTileData? {
        if let exactTileData = tileData(tile) {
            return exactTileData
        }

        var ancestorZoom = tile.z - 1
        while ancestorZoom >= minZoom {
            if let ancestor = tile.findParentTile(atZoom: ancestorZoom),
               let ancestorTileData = tileData(ancestor) {
                return ancestorTileData
            }
            ancestorZoom -= 1
        }

        return nil
    }

    func encode(layer _: RenderLayer, encoder _: MTLRenderCommandEncoder, frameContext _: FrameContext) {}

    func handleMemoryWarning() {
        clearCachedState()
    }

    func evict() {
        clearCachedState()
    }

    private func publishEmptyState(frameContext: FrameContext) {
        previousRequiredTiles = nil
        previousReadyTiles = nil
        atlasState = .empty
        frameContext.sharedState.nightLightsAtlasState = .empty
    }

    private func clearCachedState() {
        tileCache.removeAll()
        atlasTexture.removeAll()
        previousRequiredTiles = nil
        previousReadyTiles = nil
        atlasState = .empty
    }
}
