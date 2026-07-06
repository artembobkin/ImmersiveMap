// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

import Foundation
import MetalKit

final class TileRenderStore {
    struct TileRequestResult {
        let readyTilesBySource: [Tile: MetalTile?]
        let readyTilesCount: Int
        let requestedTilesCount: Int
    }

    private var mapNeedsTile: ImmersiveMapNeedsTile?
    private var memoryMetalTile: MemoryMetalTileCache!
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
        // Истечение backoff-окна будит on-demand рендер: кадр заново выполнит
        // requestTiles и ретраит провалившиеся тайлы. Без этого дыра после
        // ошибки загрузки висит до следующего жеста камеры.
        mapNeedsTile!.onRetryWindowExpired = { [weak self] in
            self?.eventSink?.invalidate(.tileRetryDue)
        }
    }
    
    func getMetalTile(tile: Tile) -> MetalTile? {
        return memoryMetalTile.getTile(forKey: tile)
    }

    // Версия содержимого кэша тайлов: меняется при материализации/вытеснении.
    // Вместе с coverageVersion образует ключ dirty-гейта demand-конвейера.
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

    func materializePreparedTile(_ preparedTile: PreparedTileCPU) async -> Bool {
        tileTraceRecorder.record(.tileMaterializeStart(preparedTile.tile))
        let metalTile = metalTileFactory.makeTile(from: preparedTile)

        await MainActor.run {
            self.memoryMetalTile.setTileData(
                tile: metalTile,
                forKey: preparedTile.tile
            )

            eventSink?.invalidate(.tileAvailable)
        }
        tileTraceRecorder.record(.tileMaterializeSuccess(preparedTile.tile))
        return true
    }

    func parseTile(tile: Tile, data: Data) async -> Bool {
        guard let result = await prepareTile(tile: tile, data: data) else {
            return false
        }
        return await materializePreparedTile(result.preparedTile)
    }

    func handleMemoryWarning() {
        mapNeedsTile?.cancelAll()
        // Trim вместо полной очистки: видимые (защищённые) тайлы остаются в кэше,
        // карта не пустеет и не перекачивает весь экран заново.
        memoryMetalTile.trim(toFractionOfLimit: 0.25)
    }

    func evict() {
        mapNeedsTile?.cancelAll()
        memoryMetalTile.removeAll()
    }
}
