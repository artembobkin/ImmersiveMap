// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import MetalKit

/// Thread-safe (`@unchecked Sendable`): references are assigned during wiring
/// before loads start, `memoryMetalTile` is mutated only on the main actor.
final class TileRenderStore: @unchecked Sendable {
    struct TileRequestResult {
        let readyTilesBySource: [Tile: MetalTile?]
        let readyTilesCount: Int
        let requestedTilesCount: Int
    }

    private var mapNeedsTile: ImmersiveMapNeedsTile?
    private var memoryMetalTile: MemoryMetalTileCache!
    // Tiles rendered from an unvalidated disk-first serve. Main-thread only:
    // mutated inside MainActor hops and read from the render frame.
    private var tilesAwaitingRevalidation: Set<Tile> = []
    private let preparedDataBuilder: TilePreparedDataBuilder
    private let metalTileFactory: MetalTileFactory
    private let tileTraceRecorder: TileTraceRecorder

    weak var eventSink: RenderFrameEventSink?

    init(
        providerRuntime: ImmersiveMapProviderRuntimeContext,
        metalDevice: MTLDevice,
        textRenderer: TextRenderer,
        config: ImmersiveMapSettings,
        tileTraceRecorder: TileTraceRecorder,
        tileLoadingStatusReporter: TileLoadingStatusReporter?
    ) {
        self.tileTraceRecorder = tileTraceRecorder
        let mapStyle = providerRuntime.mapStyle
        let preparedTileCacheIdentity = PreparedTileCacheIdentity(
            preparedFormatVersion: PreparedTileDiskCaching.preparedFormatVersion,
            styleRevision: mapStyle.preparedTileStyleRevision,
            tileSourceRevision: PreparedTileCacheIdentity.tileSourceRevision(for: config.tiles.network),
            flatSeparateRoadRenderingMinimumZoom: UInt32(max(0, config.style.flatSeparateRoadRenderingMinimumZoom)),
            textRevision: textRenderer.preparedTileTextRevision,
            labelLanguage: config.labels.language,
            labelFallbackPolicy: config.labels.fallbackPolicy,
            houseNumbersEnabled: config.labels.houseNumbers.enabled,
            houseNumbersMinimumZoom: UInt32(max(0, config.labels.houseNumbers.minimumZoom)),
            capitalMaximumZoom: UInt32(max(0, config.labels.settlementVisibility.capitalMaximumZoom)),
            cityMaximumZoom: UInt32(max(0, config.labels.settlementVisibility.cityMaximumZoom)),
            smallSettlementMaximumZoom: UInt32(max(0, config.labels.settlementVisibility.smallSettlementMaximumZoom)),
            landmarkMinimumZoom: UInt32(max(0, config.labels.landmarks.minimumZoom)),
            addTestBorders: config.tiles.parsing.addTestBorders
        )
        let determineFeatureStyle = DetermineFeatureStyle(mapStyle: mapStyle)
        let tileParser = TileMvtParser(determineFeatureStyle: determineFeatureStyle,
                                       labelProviderProfile: providerRuntime.labelProviderProfile,
                                       config: config,
                                       glyphCoverage: textRenderer.glyphCoverage)
        let textLabelsBuilder = TileTextLabelsBuilder(textRenderer: textRenderer)
        let roadLabelsBuilder = TileRoadLabelsBuilder(textRenderer: textRenderer)
        self.preparedDataBuilder = TilePreparedDataBuilder(tileParser: tileParser,
                                                           textLabelsBuilder: textLabelsBuilder,
                                                           roadLabelsBuilder: roadLabelsBuilder)
        self.metalTileFactory = MetalTileFactory(metalDevice: metalDevice)
        let maxCachedTilesMemory = config.tiles.cache.memoryCacheSizeInBytes
        memoryMetalTile = MemoryMetalTileCache(maxCacheSizeInBytes: maxCachedTilesMemory,
                                               tileTraceRecorder: tileTraceRecorder)
        mapNeedsTile = ImmersiveMapNeedsTile(tileRenderStore: self,
                                             config: config,
                                             preparedTileCacheIdentity: preparedTileCacheIdentity,
                                             tileTraceRecorder: tileTraceRecorder,
                                             tileLoadingStatusReporter: tileLoadingStatusReporter)
        // Backoff-window expiry wakes the on-demand renderer: the frame reruns
        // requestTiles and retries the failed tiles. Without this, a hole left
        // by a load failure hangs until the next camera gesture.
        mapNeedsTile!.onRetryWindowExpired = { [weak self] in
            self?.eventSink?.invalidate(.tileRetryDue)
        }
    }
    
    func getMetalTile(tile: Tile) -> MetalTile? {
        return memoryMetalTile.getTile(forKey: tile)
    }

    /// Placements can retain tiles beyond the demanded set (a stale substitute
    /// keeps drawing until its replacement arrives), so the placement
    /// subsystem reports the actually referenced tiles whenever it rebuilds:
    /// everything else in the cache goes volatile for the OS to reclaim under
    /// memory pressure.
    func recordActiveTiles(_ tiles: Set<Tile>, frameIndex: UInt64) {
        memoryMetalTile.recordActiveTiles(tiles, frameIndex: frameIndex)
    }

    // Tile cache content version: changes on materialization/eviction.
    // Together with coverageVersion it forms the demand pipeline's dirty-gate key.
    var cacheContentVersion: UInt64 {
        memoryMetalTile.contentVersion
    }

    func requestTiles(_ tiles: [Tile], frameIndex: UInt64? = nil) -> TileRequestResult {
        memoryMetalTile.updateProtectedTiles(Set(tiles))
        var readyTilesBySource: [Tile: MetalTile?] = [:]
        readyTilesBySource.reserveCapacity(tiles.count)
        var request: [Tile] = []
        var readyTilesCount = 0
        for tile in tiles {
            let metalTile = getMetalTile(tile: tile)

            // No ready tile to display; request it, load from disk or network
            // Also parse it and then store it in the cache
            if metalTile == nil {
                request.append(tile)
                // A flagged tile that lost its memory entry reloads through the
                // normal full path; the flag would only leak.
                tilesAwaitingRevalidation.remove(tile)
            } else {
                readyTilesCount += 1
                // A disk-first serve renders before it is revalidated. Demand is
                // miss-driven, so a served tile must stay requestable until some
                // load confirms or replaces it, otherwise a cancelled or failed
                // revalidation would pin stale content for as long as the tile
                // stays cached. The loader dedups in-flight tiles itself.
                if tilesAwaitingRevalidation.contains(tile) {
                    request.append(tile)
                }
            }

            // Keep tile availability for the caller.
            readyTilesBySource[tile] = metalTile
        }
        
        
        // Send all missing tiles for loading
        mapNeedsTile!.request(tiles: request)
        tileTraceRecorder.record(.tileStoreRequest(frameIndex: frameIndex,
                                                   demanded: tiles.count,
                                                   ready: readyTilesCount,
                                                   requested: request.count))

        return TileRequestResult(readyTilesBySource: readyTilesBySource,
                                 readyTilesCount: readyTilesCount,
                                 requestedTilesCount: request.count)
    }

    func prepareTile(tile: Tile, data: Data) async -> PreparedTileLoadResult? {
        tileTraceRecorder.record(.tilePrepareStart(tile))
        do {
            let result = try preparedDataBuilder.build(tile: tile, data: data)
            tileTraceRecorder.record(.tilePrepareSuccess(tile, layerTimings: result.parseLayerTimings))
            return result
        } catch {
            #if DEBUG
            print("[WARN] Failed to parse tile \(tile): \(error)")
            #endif
            tileTraceRecorder.record(.tilePrepareFailed(tile, error: error))
            return nil
        }
    }

    /// `awaitingRevalidation` marks a disk-first serve: content that is shown
    /// before its ETag is checked against the network. The store keeps such
    /// tiles requestable (see `requestTiles`) until a later materialize or
    /// `markTileRevalidated` clears the flag.
    func materializePreparedTile(_ preparedTile: PreparedTileCPU,
                                 awaitingRevalidation: Bool = false) async -> Bool {
        tileTraceRecorder.record(.tileMaterializeStart(preparedTile.tile))
        guard let metalTile = metalTileFactory.makeTile(from: preparedTile) else {
            // Backing allocation failed (memory pressure): report a
            // materialize failure so the loader's retry path owns the tile
            // instead of the cache holding a permanently blank one.
            tileTraceRecorder.record(.tileMaterializeFailed(preparedTile.tile))
            return false
        }

        await MainActor.run {
            self.memoryMetalTile.setTileData(
                tile: metalTile,
                forKey: preparedTile.tile
            )
            if awaitingRevalidation {
                self.tilesAwaitingRevalidation.insert(preparedTile.tile)
            } else {
                self.tilesAwaitingRevalidation.remove(preparedTile.tile)
            }

            eventSink?.invalidate(.tileAvailable)
        }
        tileTraceRecorder.record(.tileMaterializeSuccess(preparedTile.tile))
        return true
    }

    /// The revalidation download confirmed (or knowingly accepted, for the
    /// offline fallback) the content served from disk: the tile no longer needs
    /// to stay requestable.
    func markTileRevalidated(_ tile: Tile) async {
        await MainActor.run {
            // A superseded load (cancelAll + re-request) must not clear the
            // flag its successor has just set: the successor's revalidation
            // is still owed.
            guard Task.isCancelled == false else {
                return
            }
            if self.tilesAwaitingRevalidation.remove(tile) != nil {
                // The silent confirm path materializes nothing, so without an
                // invalidation anyone polling requestedTilesCount off rendered
                // diagnostics (the video export settle loop) would wait out
                // its full timeout on an already-resolved tile.
                self.eventSink?.invalidate(.tileAvailable)
            }
        }
    }

    /// Stops the tile loader when the owning engine is being discarded
    /// (renderer recreation, view-reuse pool drop, export teardown). Without
    /// this the orphaned loader keeps draining its queue against a dead store,
    /// and dead-store materialize failures masquerade as corruption and delete
    /// valid prepared-disk entries.
    func cancelLoading() {
        mapNeedsTile?.cancelAll()
    }

    func parseTile(tile: Tile, data: Data) async -> Bool {
        guard let result = await prepareTile(tile: tile, data: data) else {
            return false
        }
        return await materializePreparedTile(result.preparedTile)
    }

    func handleMemoryWarning() {
        mapNeedsTile?.cancelAll()
        // Trim instead of a full clear: visible (protected) tiles stay in the
        // cache, so the map does not go blank and does not redownload the
        // whole screen.
        memoryMetalTile.trim(toFractionOfLimit: 0.25)
    }

    func evict() {
        mapNeedsTile?.cancelAll()
        memoryMetalTile.removeAll()
    }
}
