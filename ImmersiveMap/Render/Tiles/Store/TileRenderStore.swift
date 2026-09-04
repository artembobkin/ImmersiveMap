// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import MetalKit

/// Thread-safe (`@unchecked Sendable`): references are assigned during wiring
/// before loads start, `workingSet` is internally synchronized and mutated
/// only through main-actor hops.
final class TileRenderStore: @unchecked Sendable {
    struct TileRequestResult {
        let readyTilesBySource: [Tile: MetalTile?]
        let readyTilesCount: Int
        let requestedTilesCount: Int
    }

    private var mapNeedsTile: ImmersiveMapNeedsTile?
    private var workingSet: TileWorkingSetStore!
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
            addTestBorders: config.tiles.parsing.addTestBorders,
            roofShapesEnabled: config.style.buildingRoofShapesEnabled,
            streetscapeRevision: PreparedTileCacheIdentity.streetscapeRevision(for: config.tiles)
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
        workingSet = TileWorkingSetStore(tileTraceRecorder: tileTraceRecorder)
        // The factory owns the MTLIO capability decision: the transport that
        // writes file entries is selected only when the queue that loads them
        // actually exists, so a queue-creation failure degrades to inline
        // entries instead of a cache no hit can read.
        let geometryTransport: any PreparedTileGeometryTransporting =
            metalTileFactory.loadsFileBlobs
                ? MTLIOPreparedTileGeometryTransport(
                    compressionEnabled: config.tiles.cache.preparedDiskCompressionEnabled)
                : InlinePreparedTileGeometryTransport()
        mapNeedsTile = ImmersiveMapNeedsTile(tileRenderStore: self,
                                             config: config,
                                             preparedTileCacheIdentity: preparedTileCacheIdentity,
                                             geometryTransport: geometryTransport,
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
        return workingSet.tile(forKey: tile)
    }

    // Working-set content version: changes on insert and release.
    // Together with coverageVersion it forms the demand pipeline's dirty-gate key.
    var cacheContentVersion: UInt64 {
        workingSet.contentVersion
    }

    func requestTiles(_ tiles: [Tile], frameIndex: UInt64? = nil) -> TileRequestResult {
        workingSet.updateDemandedTiles(Set(tiles))
        var readyTilesBySource: [Tile: MetalTile?] = [:]
        readyTilesBySource.reserveCapacity(tiles.count)
        var request: [Tile] = []
        var readyTilesCount = 0
        for tile in tiles {
            let metalTile = getMetalTile(tile: tile)

            // No ready tile to display; request it, load from disk or network
            // Also parse it and then store it in the working set
            if metalTile == nil {
                request.append(tile)
            } else {
                readyTilesCount += 1
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

    /// `plan` is the tile's arena plan when the caller already built one
    /// (the loader shares it with the disk save so the layout work runs once).
    func materializePreparedTile(_ preparedTile: PreparedTileCPU,
                                 plan: TileArenaImagePlan? = nil) async -> Bool {
        tileTraceRecorder.record(.tileMaterializeStart(preparedTile.tile))
        guard let metalTile = metalTileFactory.makeTile(from: preparedTile, plan: plan) else {
            // Backing allocation failed (memory pressure): report a
            // materialize failure so the loader's retry path owns the tile
            // instead of the cache holding a permanently blank one.
            tileTraceRecorder.record(.tileMaterializeFailed(preparedTile.tile))
            return false
        }

        await publishMaterializedTile(metalTile, forKey: preparedTile.tile)
        tileTraceRecorder.record(.tileMaterializeSuccess(preparedTile.tile))
        return true
    }

    /// The arena-image sibling of `materializePreparedTile`: a disk hit is
    /// blob bytes plus a span table, so the factory copies (or MTLIO-loads)
    /// instead of rebuilding buffers from decoded arrays.
    func materializeArenaImage(_ image: PreparedTileArenaImage) async -> PreparedTileMaterializeOutcome {
        tileTraceRecorder.record(.tileMaterializeStart(image.tile))
        let result = await metalTileFactory.makeTile(fromImage: image)
        let metalTile: MetalTile
        switch result {
        case .tile(let tile):
            metalTile = tile
        case .allocationFailed:
            tileTraceRecorder.record(.tileMaterializeFailed(image.tile))
            return .allocationOrStoreFailed
        case .imageUnreadable:
            tileTraceRecorder.record(.tileMaterializeFailed(image.tile))
            return .imageUnreadable
        }

        await publishMaterializedTile(metalTile, forKey: image.tile)
        tileTraceRecorder.record(.tileMaterializeSuccess(image.tile))
        return .materialized
    }

    /// Shared tail of both materialize paths: stores the tile and invalidates
    /// a frame so the on-demand renderer draws it.
    private func publishMaterializedTile(_ metalTile: MetalTile,
                                         forKey key: Tile) async {
        await MainActor.run {
            self.workingSet.insert(metalTile, forKey: key)
            eventSink?.invalidate(.tileAvailable)
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
        // The demanded tiles stay resident, so the map does not go blank and
        // does not reload the screen; only the off-screen residue (the world
        // cover included) is handed back, to warm up again from the prepared
        // disk cache.
        workingSet.releaseUndemandedTiles()
    }

    func evict() {
        mapNeedsTile?.cancelAll()
        workingSet.removeAll()
    }
}
