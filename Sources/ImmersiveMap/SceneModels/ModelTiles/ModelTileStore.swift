// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import os
import PMTiles

/// Loads the model tiles a frame wants and releases the ones it has left.
///
/// A frame names the tiles in and around its view (`meshes(for:)`). The
/// store answers with the ones already on the GPU and starts loading the
/// rest, a few at a time, nearest first. A tile that arrives invalidates a
/// frame through `eventSink`, as a map tile does, so the on-demand render
/// loop draws it without waiting for a gesture.
///
/// The tiles a frame wants are never released. The ones the camera has left
/// stay, so a return costs nothing, until the total passes the memory
/// budget, and then the longest unused go first. A memory warning releases
/// everything the last frame did not want.
///
/// A tile the archive does not have is remembered as empty and never asked
/// again. A tile that could not be fetched is asked again after a pause
/// that grows with each failure, for as long as a frame wants it.
///
/// Thread-safe (`@unchecked Sendable`): the loads run in tasks off the main
/// thread and all mutable state is serialized by `lock`.
final class ModelTileStore: @unchecked Sendable {
    /// The zoom of the tiles a model archive holds. Its models are grouped
    /// by the map tile of this zoom their origin lies in.
    static let tileZoom = 14
    static let maximumConcurrentLoads = 4
    static let retryBaseDelay: TimeInterval = 5
    static let retryMaximumDelay: TimeInterval = 60
    /// The empty tiles remembered before the list starts over: a session
    /// that has crossed this many tiles has long left the first ones.
    static let maximumRememberedEmptyTiles = 16_384

    private static let logger = Logger(subsystem: "ImmersiveMap", category: "ModelTiles")

    private enum LoadState {
        /// On its way. `failedAttempts` is how many loads of the tile have
        /// failed before this one, for the pause after the next failure.
        case loading(failedAttempts: Int)
        case failed(attempts: Int, retryAt: TimeInterval)
    }

    private enum LoadFailure: Error {
        /// The bytes are not a tile this engine reads. Asking again would
        /// bring the same bytes.
        case unreadable(String)
        /// The archive could not answer. Worth asking again.
        case unavailable(String)
    }

    weak var eventSink: RenderFrameEventSink?

    private let device: MTLDevice
    private let schema: any ImmersiveMapTileSchema
    private let loadTile: @Sendable (Tile) async throws -> ModelTileSource.Outcome
    private let discardCachedTile: @Sendable (Tile) -> Void
    private let costLimitBytes: Int
    private let now: @Sendable () -> TimeInterval

    private let lock = NSLock()
    private var cache: LRUMemoryCache<Tile, ModelTileMesh>
    private var statesByTile: [Tile: LoadState] = [:]
    private var emptyTiles: Set<Tile> = []
    private var wantedTiles: Set<Tile> = []

    convenience init(device: MTLDevice,
                     schema: any ImmersiveMapTileSchema,
                     source: ModelTileSource,
                     costLimitBytes: Int) {
        self.init(device: device,
                  schema: schema,
                  costLimitBytes: costLimitBytes,
                  loadTile: { tile in try await source.tileBytes(tile) },
                  discardCachedTile: { tile in source.discardCachedTile(tile) })
    }

    /// The store of a map's settings: nil for a map without a model
    /// archive, and for a device whose GPU does not sample the textures a
    /// model tile carries, where the map keeps its own buildings.
    static func make(settings: ImmersiveMapSettings,
                     device: MTLDevice,
                     schema: any ImmersiveMapTileSchema) -> ModelTileStore? {
        guard let archive = settings.modelArchive else {
            return nil
        }
        guard ModelTileMesh.isSupported(device: device) else {
            if ModelTileNoticeThrottle.unsupportedDevice.shouldLog() {
                logger.warning("ImmersiveMap: this device's GPU has no ASTC textures, so the model archive is not loaded and the map draws its own buildings.")
            }
            return nil
        }
        return ModelTileStore(device: device,
                              schema: schema,
                              source: ModelTileSource(settings: archive,
                                                      clearsDiskCache: settings.tiles.cache.clearDiskCachesOnLaunch),
                              costLimitBytes: archive.memoryBudgetInBytes)
    }

    /// The test seam: the tile bytes from a closure, and a clock.
    init(device: MTLDevice,
         schema: any ImmersiveMapTileSchema,
         costLimitBytes: Int,
         loadTile: @escaping @Sendable (Tile) async throws -> ModelTileSource.Outcome,
         discardCachedTile: @escaping @Sendable (Tile) -> Void = { _ in },
         now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.device = device
        self.schema = schema
        self.costLimitBytes = max(0, costLimitBytes)
        self.cache = LRUMemoryCache(costLimit: max(0, costLimitBytes))
        self.loadTile = loadTile
        self.discardCachedTile = discardCachedTile
        self.now = now
    }

    /// One call per frame. `wanted` is the tiles the frame wants, nearest
    /// first: that is the order the missing ones start loading in. Returns
    /// the wanted tiles that are on the GPU now, in the same order, and the
    /// ones still on their way. A tile waiting out its retry after a
    /// failure is not on its way: what waits for it does not wait forever.
    func meshes(for wanted: [Tile]) -> (ready: [ModelTileMesh], pending: [Tile]) {
        var ready: [ModelTileMesh] = []
        var tilesToLoad: [Tile] = []
        var pending: [Tile] = []

        lock.lock()
        wantedTiles = Set(wanted)
        var runningCount = statesByTile.values.reduce(0) { count, state in
            if case .loading = state { return count + 1 }
            return count
        }
        let time = now()
        for tile in wanted {
            if let mesh = cache.value(forKey: tile) {
                ready.append(mesh)
                continue
            }
            if emptyTiles.contains(tile) {
                continue
            }
            switch statesByTile[tile] {
            case .loading:
                pending.append(tile)
            case .failed(_, let retryAt) where time < retryAt:
                break
            case .failed, nil:
                // Past the limit the tile waits for a later frame: a load
                // that ends invalidates one.
                pending.append(tile)
                if runningCount < Self.maximumConcurrentLoads {
                    runningCount += 1
                    tilesToLoad.append(tile)
                }
            }
        }
        for tile in tilesToLoad {
            var failedAttempts = 0
            if case .failed(let attempts, _) = statesByTile[tile] {
                failedAttempts = attempts
            }
            statesByTile[tile] = .loading(failedAttempts: failedAttempts)
        }
        lock.unlock()

        for tile in tilesToLoad {
            startLoad(tile)
        }
        return (ready, pending)
    }

    func handleMemoryWarning() {
        lock.lock()
        _ = cache.trim(toCost: 0, protectedKeys: wantedTiles)
        lock.unlock()
    }

    func evict() {
        lock.lock()
        _ = cache.trim(toCost: costLimitBytes, protectedKeys: wantedTiles)
        lock.unlock()
    }

    /// What the loaded tiles hold on the GPU, for diagnostics and tests.
    var residentCostInBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.totalCost
    }

    var residentTiles: Set<Tile> {
        lock.lock()
        defer { lock.unlock() }
        return Set(cache.keys)
    }

    // MARK: - Loading

    private func startLoad(_ tile: Tile) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                switch try await self.fetch(tile) {
                case .mesh(let mesh):
                    self.finishLoad(tile, mesh: mesh)
                case .empty:
                    self.finishLoad(tile, mesh: nil)
                }
            } catch LoadFailure.unreadable(let reason) {
                Self.logger.warning("ImmersiveMap: model tile \(tile.z, privacy: .public)/\(tile.x, privacy: .public)/\(tile.y, privacy: .public) cannot be read (\(reason, privacy: .public)). Its models are not drawn. Check that the model archive was baked for this version of the engine.")
                self.finishLoad(tile, mesh: nil)
            } catch {
                self.failLoad(tile)
            }
        }
    }

    private enum Fetched {
        case mesh(ModelTileMesh)
        case empty
    }

    private func fetch(_ tile: Tile) async throws -> Fetched {
        let outcome: ModelTileSource.Outcome
        do {
            outcome = try await loadTile(tile)
        } catch PMTilesArchiveClient.Failure.archiveUnreadable(let reason) {
            // Not an archive of model tiles, or not one at all: nothing a
            // retry changes soon, but the URL may be fixed on the server,
            // so it stays a failure with a pause and not an empty tile.
            if ModelTileNoticeThrottle.archiveUnreadable.shouldLog() {
                Self.logger.warning("ImmersiveMap: the model archive could not be read (\(reason, privacy: .public)). Check that modelArchive(_:headers:) points at a PMTiles v3 archive of model tiles.")
            }
            throw LoadFailure.unavailable(reason)
        } catch {
            throw LoadFailure.unavailable("\(error)")
        }
        guard case .tile(let data, let fileURL) = outcome else {
            return .empty
        }
        do {
            let contents = try ModelTileContents(decoding: data)
            guard contents.tile == tile else {
                throw ModelTileFormatError.malformed("the tile says it is \(contents.tile.z)/\(contents.tile.x)/\(contents.tile.y)")
            }
            return .mesh(try await ModelTileMesh.make(contents: contents,
                                                      data: data,
                                                      fileURL: fileURL,
                                                      device: device,
                                                      schema: schema))
        } catch let error as ModelTileFormatError {
            // The bytes may be a cached file cut short: without it the next
            // session reads the archive again.
            discardCachedTile(tile)
            throw LoadFailure.unreadable("\(error)")
        } catch {
            throw LoadFailure.unavailable("\(error)")
        }
    }

    private func finishLoad(_ tile: Tile, mesh: ModelTileMesh?) {
        lock.lock()
        statesByTile.removeValue(forKey: tile)
        if let mesh {
            _ = cache.setValue(mesh, forKey: tile, cost: mesh.costInBytes, protectedKeys: wantedTiles)
        } else {
            if emptyTiles.count >= Self.maximumRememberedEmptyTiles {
                emptyTiles.removeAll(keepingCapacity: true)
            }
            emptyTiles.insert(tile)
        }
        lock.unlock()
        // An empty tile changes no picture, but a load that ended frees a
        // slot the next waiting tile takes on the frame this asks for.
        eventSink?.invalidate(.sceneModelAssetLoaded)
    }

    private func failLoad(_ tile: Tile) {
        lock.lock()
        var attempts = 1
        if case .loading(let failedAttempts) = statesByTile[tile] {
            attempts = failedAttempts + 1
        }
        let delay = min(Self.retryMaximumDelay, Self.retryBaseDelay * pow(2, Double(attempts - 1)))
        statesByTile[tile] = .failed(attempts: attempts, retryAt: now() + delay)
        lock.unlock()

        // The slot is free now, and the pause's end must draw a frame:
        // on-demand rendering would otherwise wait for a gesture.
        eventSink?.invalidate(.sceneModelAssetLoaded)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.eventSink?.invalidate(.sceneModelAssetLoaded)
        }
    }
}

/// Throttles a warning about the model archive to one line per interval,
/// process wide: every wanted tile carries the same news.
///
/// `@unchecked Sendable` because the lock is the synchronisation the
/// compiler cannot see: the state is private and every path to it goes
/// through `lock`.
final class ModelTileNoticeThrottle: @unchecked Sendable {
    static let archiveUnreadable = ModelTileNoticeThrottle()
    static let unsupportedDevice = ModelTileNoticeThrottle()
    static let interval: TimeInterval = 60

    private let lock = NSLock()
    private var lastLoggedAt: Date?

    func shouldLog(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let last = lastLoggedAt, now.timeIntervalSince(last) < Self.interval {
            return false
        }
        lastLoggedAt = now
        return true
    }
}
