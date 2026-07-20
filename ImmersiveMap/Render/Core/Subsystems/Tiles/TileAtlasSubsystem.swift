// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

//
//  TileAtlasSubsystem.swift
//  ImmersiveMap
//

import Foundation
import Metal

final class TileAtlasSubsystem: RenderSubsystem {
    let name: String = "Tiles"

    private let tilesTexture: TileAtlasTexture
    private let tileTraceRecorder: TileTraceRecorder

    private let atlasQualityScale: Float = 1.0
    private var globeTextureVersionTracker = StagedHashChangeTracker()
    private var atlasPlanCacheKey: TileAtlasPlanCacheKey?
    private var placeTilesContext: TileAtlasPlaceTilesContext = .empty
    private var atlasPlan: TileAtlasPlan = .empty
    private var overviewFadeAlpha: Float = 1.0
    private var roadFadeAlpha: Float = 0.0
    private var landuseFadeAlpha: Float = 0.0
    private var tileAtlasDebugSummary: TileAtlasDebugSummary?

    init(tilesTexture: TileAtlasTexture,
         tileTraceRecorder: TileTraceRecorder) {
        self.tilesTexture = tilesTexture
        self.tileTraceRecorder = tileTraceRecorder
    }

    func update(frameContext: FrameContext) {
        let tilePlacementState = frameContext.sharedState.tilePlacementState
        placeTilesContext = tilePlacementState.tileAtlasPlaceTilesContext
        overviewFadeAlpha = LowZoomOverviewFade.alpha(for: frameContext.zoom, kind: .overviewFeatures)
        roadFadeAlpha = LowZoomOverviewFade.alpha(for: frameContext.zoom, kind: .roads)
        landuseFadeAlpha = LowZoomOverviewFade.alpha(for: frameContext.zoom, kind: .landuse)
        updateAtlasPlanIfNeeded(frameContext: frameContext,
                                placementVersion: tilePlacementState.placementVersion)
        refreshDebugSummaryIfNeeded(frameContext: frameContext)
        frameContext.sharedState.tileAtlasDebugSummary = frameContext.renderSurfaceMode == .spherical ? tileAtlasDebugSummary : nil

        var hasher = Hasher()
        hasher.combine(Int(truncatingIfNeeded: tilePlacementState.placementVersion))
        hasher.combine(overviewFadeAlpha.bitPattern)
        hasher.combine(roadFadeAlpha.bitPattern)
        hasher.combine(landuseFadeAlpha.bitPattern)
        combineAtlasPlanHash(atlasPlan, into: &hasher)
        let textureChanged = globeTextureVersionTracker.stage(hasher.finalize())
        tileTraceRecorder.record(.atlasTextureStage(frameIndex: frameContext.frameIndex,
                                                    textureChanged: textureChanged,
                                                    placementVersion: tilePlacementState.placementVersion,
                                                    plan: atlasPlan,
                                                    surface: frameContext.renderSurfaceMode == .spherical ? "globe" : "flat"))
    }

    func prepareGPU(frameContext: FrameContext, resourceRegistry _: RenderResourceRegistry) {
        guard globeTextureVersionTracker.hasPendingChange else {
            return
        }
        guard let commandBuffer = frameContext.commandBuffer else {
            frameContext.services.diagnostics.recordSkipReason(.missingCommandBuffer)
            return
        }

        renderTileAtlasTextureIfNeeded(commandBuffer: commandBuffer, frameContext: frameContext)
    }

    func encode(layer _: RenderLayer, encoder _: MTLRenderCommandEncoder, frameContext _: FrameContext) {}

    // Хеш атласа фиксируется только после commit() command buffer: если кадр
    // отброшен (нет drawable), закодированная перерисовка страниц не выполнится,
    // и pending-хеш должен пережить кадр, чтобы следующий кадр перекодировал
    // атлас заново - иначе шейдер сэмплит старую GPU-текстуру по новому маппингу.
    func frameCommitted() {
        globeTextureVersionTracker.commitPending()
    }

    func handleMemoryWarning() {
        placeTilesContext = .empty
        atlasPlan = .empty
        atlasPlanCacheKey = nil
        tileAtlasDebugSummary = nil
        globeTextureVersionTracker.invalidate()
        tilesTexture.releasePages()
    }

    func evict() {
        placeTilesContext = .empty
        atlasPlan = .empty
        atlasPlanCacheKey = nil
        tileAtlasDebugSummary = nil
        globeTextureVersionTracker.invalidate()
        tilesTexture.releasePages()
    }

    private func renderTileAtlasTextureIfNeeded(commandBuffer: MTLCommandBuffer,
                                                 frameContext: FrameContext) {
        guard frameContext.renderSurfaceMode == .spherical else { return }

        drawGlobeTexture(commandBuffer: commandBuffer, frameContext: frameContext)
    }

    private func drawGlobeTexture(commandBuffer: MTLCommandBuffer,
                                  frameContext: FrameContext) {
        tilesTexture.resetFrame()

        let allocationsByPage = Dictionary(grouping: atlasPlan.allocations, by: \.pageIndex)
        tileTraceRecorder.record(.atlasTextureRedraw(frameIndex: frameContext.frameIndex,
                                                     plan: atlasPlan,
                                                     encodedPages: allocationsByPage.count))

        var encodedPageIndexes: [Int] = []
        for pageIndex in allocationsByPage.keys.sorted() {
            guard let allocations = allocationsByPage[pageIndex],
                  tilesTexture.beginPageEncoding(commandBuffer: commandBuffer, pageIndex: pageIndex) else {
                continue
            }

            tilesTexture.setOverviewFadeAlphas(overviewAlpha: overviewFadeAlpha,
                                               roadAlpha: roadFadeAlpha,
                                               landuseAlpha: landuseFadeAlpha)
            tilesTexture.selectTilePipeline()

            for allocation in allocations {
                let placed = tilesTexture.draw(allocation: allocation)
                if placed == false {
                    #if DEBUG
                    print("[ERROR] No place for tile in globe atlas texture!")
                    #endif
                    break
                }
            }

            tilesTexture.endEncoding()
            encodedPageIndexes.append(pageIndex)
        }

        tilesTexture.generateMipmaps(commandBuffer: commandBuffer,
                                     pageIndexes: encodedPageIndexes)
    }

    private func makeAtlasPlan(frameContext: FrameContext) -> TileAtlasPlan {
        guard frameContext.renderSurfaceMode == .spherical else { return .empty }

        let planner = TileAtlasPlacementPlanner(pageSizePx: tilesTexture.size,
                                                 qualityScale: atlasQualityScale)
        let candidates = planner.makeCandidates(placeTiles: placeTilesContext.tilePlacements,
                                                frameContext: frameContext)
        return planner.plan(candidates: candidates)
    }

    private func updateAtlasPlanIfNeeded(frameContext: FrameContext,
                                         placementVersion: UInt64) {
        let cacheKey = TileAtlasPlanCacheKey(renderSurfaceMode: frameContext.renderSurfaceMode,
                                             placementVersion: placementVersion,
                                             drawSize: frameContext.drawSize,
                                             cameraUniform: frameContext.cameraUniform,
                                             globe: frameContext.globeRenderUniform,
                                             textureSize: tilesTexture.size,
                                             qualityScale: atlasQualityScale)
        guard atlasPlanCacheKey != cacheKey else {
            tileTraceRecorder.record(.atlasPlanReused(frameIndex: frameContext.frameIndex,
                                                      placementVersion: placementVersion,
                                                      plan: atlasPlan,
                                                      surface: frameContext.renderSurfaceMode == .spherical ? "globe" : "flat"))
            return
        }

        atlasPlan = makeAtlasPlan(frameContext: frameContext)
        atlasPlanCacheKey = cacheKey
        tileAtlasDebugSummary = nil
        tileTraceRecorder.record(.atlasPlanRebuilt(frameIndex: frameContext.frameIndex,
                                                   placementVersion: placementVersion,
                                                   plan: atlasPlan,
                                                   surface: frameContext.renderSurfaceMode == .spherical ? "globe" : "flat"))
    }

    // Summary нужен только HUD-панели: строим лениво при включённой панели,
    // а не на каждый rebuild плана (rebuild происходит каждый кадр движения камеры).
    private func refreshDebugSummaryIfNeeded(frameContext: FrameContext) {
        guard frameContext.services.settings.debug.enableDebugPanel else {
            tileAtlasDebugSummary = nil
            return
        }
        if tileAtlasDebugSummary == nil {
            tileAtlasDebugSummary = TileAtlasDebugSummary(plan: atlasPlan)
        }
    }

    private func combineAtlasPlanHash(_ atlasPlan: TileAtlasPlan,
                                      into hasher: inout Hasher) {
        hasher.combine(atlasPlan.allocations.count)
        hasher.combine(atlasPlan.pageSummaries.count)
        hasher.combine(atlasPlan.downgradedAllocationCount)
        hasher.combine(atlasPlan.skippedAllocationCount)

        for allocation in atlasPlan.allocations {
            hasher.combine(allocation.pageIndex)
            hasher.combine(allocation.placedPosition.x)
            hasher.combine(allocation.placedPosition.y)
            hasher.combine(allocation.atlasDepth.rawValue)
            hasher.combine(allocation.cellSizePx)
            hasher.combine(allocation.placeTile.metalTile.tile)
            hasher.combine(allocation.placeTile.placeIn.tile)
            hasher.combine(allocation.placeTile.lodKind)
        }
    }
}
