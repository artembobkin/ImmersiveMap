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
    private var lineWidthZoomTaper: Float = 1.0
    private var tileAtlasDebugSummary: TileAtlasDebugSummary?
    private var pageRetention = TileAtlasPageRetention()

    init(tilesTexture: TileAtlasTexture,
         tileTraceRecorder: TileTraceRecorder) {
        self.tilesTexture = tilesTexture
        self.tileTraceRecorder = tileTraceRecorder
    }

    func update(frameContext: FrameContext) {
        releaseStalePagesIfNeeded(frameContext: frameContext)

        let tilePlacementState = frameContext.sharedState.tilePlacementState
        placeTilesContext = tilePlacementState.tileAtlasPlaceTilesContext
        overviewFadeAlpha = LowZoomOverviewFade.alpha(for: frameContext.zoom, kind: .overviewFeatures)
        roadFadeAlpha = LowZoomOverviewFade.alpha(for: frameContext.zoom, kind: .roads)
        landuseFadeAlpha = LowZoomOverviewFade.alpha(for: frameContext.zoom, kind: .landuse)
        lineWidthZoomTaper = LineWidthZoomTaper.scale(for: frameContext.zoom)
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

    // The atlas hash is committed only after the command buffer commit(): if the
    // frame is dropped (no drawable), the encoded page redraw never executes,
    // and the pending hash must survive the frame so the next frame re-encodes
    // the atlas - otherwise the shader samples the old GPU texture with the new mapping.
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

    // The globe atlas is only needed in spherical mode: after a stable switch to
    // flat its pages are released so we don't hold hundreds of MiB of dead textures.
    private func releaseStalePagesIfNeeded(frameContext: FrameContext) {
        guard pageRetention.shouldReleasePages(isSpherical: frameContext.renderSurfaceMode == .spherical,
                                               hasPages: tilesTexture.pages.isEmpty == false,
                                               time: frameContext.time) else {
            return
        }
        evict()
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
                                               landuseAlpha: landuseFadeAlpha,
                                               pixelsPerPoint: Float(frameContext.pixelsPerPoint),
                                               lineWidthZoomTaper: lineWidthZoomTaper,
                                               drawableHeightPx: Float(frameContext.drawSize.height),
                                               nativeTileWorldSize: Float(2.0 * Double.pi
                                                   * frameContext.services.settings.presentation.globeRadiusScale))
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

    // The summary is only needed by the HUD panel: build it lazily when the panel
    // is enabled, not on every plan rebuild (a rebuild happens every frame of camera motion).
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
            // Quantized, so the fractional-zoom dolly re-bakes the pages in
            // coarse steps: point-locked line widths bake in texels through
            // this ratio (with the low-zoom taper folded in), and a stale
            // ratio is exactly the on-screen width pump the point lock exists
            // to remove.
            hasher.combine(TileAtlasAllocation.lineWidthRasterScale(
                cellSizePx: allocation.cellSizePx,
                screenDemandPx: allocation.candidate.screenDemandPx,
                zoomTaper: lineWidthZoomTaper
            ).bitPattern)
        }
    }
}
