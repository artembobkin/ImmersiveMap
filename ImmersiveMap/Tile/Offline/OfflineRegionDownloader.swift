// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import os

/// Fetches a region's tiles into an `OfflineTileStore` with bounded
/// concurrency, resuming past whatever is already stored.
///
/// Behavior per tile:
/// - already stored (bytes or an empty marker): counted, never refetched;
/// - fetched bytes: written and counted;
/// - "nothing here" answers (404, 410, empty body): stored as an empty marker
///   and counted, so a coastal region with ocean tiles still completes;
/// - transport and server failures: retried a few times with a short pause,
///   then counted as failed (a later download run tries them again);
/// - authorization failures: the whole run aborts, because every remaining
///   tile would fail the same way.
///
/// Cancellation of the surrounding task stops the run between tiles and
/// leaves everything already stored on disk.
struct OfflineRegionDownloader: Sendable {
    typealias FetchTile = @Sendable (Tile) async -> TileDownloader.DownloadResult

    struct Progress: Equatable, Sendable {
        var expectedTileCount = 0
        var storedTileCount = 0
        var failedTileCount = 0
        var byteCount: Int64 = 0

        var processedTileCount: Int {
            storedTileCount + failedTileCount
        }
    }

    struct Summary: Equatable, Sendable {
        var progress: Progress
        var isComplete: Bool
        /// The run stopped on 401/403/missing token. Every remaining tile
        /// would fail the same way, so retrying without new credentials is
        /// pointless; the status surfaces this so an app can say so.
        var wasBlockedByAuthorization: Bool
    }

    private enum TileOutcome {
        case stored(byteCount: Int64)
        case failed
        case aborted
        case cancelled
    }

    private static let logger = Logger(subsystem: "ImmersiveMap", category: "OfflineTiles")

    let store: OfflineTileStore
    let fetchTile: FetchTile
    var maxConcurrentFetches = 5
    var fetchAttemptsPerTile = 3
    /// Injectable pause between retry attempts so tests run without waiting.
    var pause: @Sendable (TimeInterval) async -> Void = { seconds in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
    /// Called after roughly every `progressReportStride` processed tiles from
    /// the run's own task; the final state arrives via the returned outcome.
    var onProgress: @Sendable (Progress) -> Void = { _ in }
    var progressReportStride = 32

    func run(tiles: [Tile]) async -> Summary {
        var progress = Progress(expectedTileCount: tiles.count)
        var aborted = false
        var cancelled = false

        await withTaskGroup(of: TileOutcome.self) { group in
            var iterator = tiles.makeIterator()

            @discardableResult
            func startNextTile() -> Bool {
                guard let tile = iterator.next() else {
                    return false
                }
                group.addTask {
                    await process(tile: tile)
                }
                return true
            }

            for _ in 0..<max(maxConcurrentFetches, 1) {
                startNextTile()
            }

            for await outcome in group {
                switch outcome {
                case let .stored(byteCount):
                    progress.storedTileCount += 1
                    progress.byteCount += byteCount
                case .failed:
                    progress.failedTileCount += 1
                case .aborted:
                    aborted = true
                    group.cancelAll()
                case .cancelled:
                    cancelled = true
                }
                if aborted == false, cancelled == false, Task.isCancelled == false {
                    startNextTile()
                }
                if progress.processedTileCount > 0,
                   progress.processedTileCount % max(progressReportStride, 1) == 0 {
                    onProgress(progress)
                }
            }
        }

        if Task.isCancelled {
            cancelled = true
        }
        let isComplete = aborted == false && cancelled == false
            && progress.storedTileCount == progress.expectedTileCount
        return Summary(progress: progress,
                       isComplete: isComplete,
                       wasBlockedByAuthorization: aborted)
    }

    private func process(tile: Tile) async -> TileOutcome {
        if Task.isCancelled {
            return .cancelled
        }
        if let existingByteCount = store.storedByteCount(of: tile) {
            return .stored(byteCount: existingByteCount)
        }

        for attempt in 1...max(fetchAttemptsPerTile, 1) {
            if Task.isCancelled {
                return .cancelled
            }
            switch await fetchTile(tile) {
            case let .success(data, _):
                do {
                    try store.writeTile(tile, data: data)
                    return .stored(byteCount: Int64(data.count))
                } catch {
                    Self.logger.warning("Failed to store offline tile z\(tile.z)/\(tile.x)/\(tile.y): \(String(describing: error), privacy: .public)")
                    return .failed
                }
            case .failure(.notFound), .failure(.gone), .failure(.emptyBody):
                do {
                    try store.writeEmptyTileMarker(tile)
                    return .stored(byteCount: 0)
                } catch {
                    return .failed
                }
            case .failure(.unauthorized), .failure(.forbidden), .failure(.missingAuthorizationToken):
                Self.logger.warning("Offline region download aborted: tile requests are not authorized.")
                return .aborted
            case let .failure(.rateLimited(retryAfter)):
                guard attempt < fetchAttemptsPerTile else {
                    return .failed
                }
                // A CDN may legally answer with a multi-minute Retry-After; a
                // bulk download must not park one of its few fetch slots that
                // long. Past the clamp the tile just counts as failed and a
                // later download run picks it up.
                await pause(min(max(retryAfter ?? 2.0, 0), 30.0))
            case .failure:
                guard attempt < fetchAttemptsPerTile else {
                    return .failed
                }
                await pause(0.5 * Double(attempt))
            }
        }
        return .failed
    }
}
