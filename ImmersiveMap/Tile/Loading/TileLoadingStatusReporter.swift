// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

struct TileLoadingPhaseSnapshot: Equatable {
    let inFlight: Int
    let completed: Int
    let failed: Int
}

enum TileLoadingTileStatus: Equatable {
    case queued
    case loading
    case parsing
    case ready
    case failed
}

struct TileLoadingStatusTileSnapshot: Equatable {
    let tile: Tile
    let status: TileLoadingTileStatus
    let progress: Double
    let detail: String
    let preparationStages: [TilePreparationStageSnapshot]

    init(tile: Tile,
         status: TileLoadingTileStatus,
         progress: Double,
         detail: String,
         preparationStages: [TilePreparationStageSnapshot] = []) {
        self.tile = tile
        self.status = status
        self.progress = progress
        self.detail = detail
        self.preparationStages = preparationStages
    }
}

struct TilePreparationStageSnapshot: Equatable {
    let name: String
    let duration: TimeInterval?
    let layerTimings: [TileParseLayerTiming]

    init(name: String,
         duration: TimeInterval?,
         layerTimings: [TileParseLayerTiming] = []) {
        self.name = name
        self.duration = duration
        self.layerTimings = layerTimings
    }
}

struct TileLoadingStatusSnapshot: Equatable {
    let requested: Int
    let deduplicated: Int
    let activeLoads: Int
    let scheduled: Int
    let network: TileLoadingPhaseSnapshot
    let parsing: TileLoadingPhaseSnapshot
    let totalCompleted: Int
    let totalFailed: Int
    let networkBytes: Int
    let latestNetworkTile: Tile?
    let latestParsingTile: Tile?
    let latestFailure: String?
    let latestParseLayerTimingTile: Tile?
    let latestParseLayerTimings: [TileParseLayerTiming]
    let tiles: [TileLoadingStatusTileSnapshot]

    var lines: [String] {
        guard requested > 0 || activeLoads > 0 || scheduled > 0 || totalCompleted > 0 || totalFailed > 0 else {
            return []
        }

        var output = [
            "tiles req:\(requested) dedup:\(deduplicated) active:\(activeLoads) scheduled:\(scheduled)",
            "network in:\(network.inFlight) done:\(network.completed) fail:\(network.failed) bytes:\(networkBytes)",
            "parse in:\(parsing.inFlight) done:\(parsing.completed) fail:\(parsing.failed)",
            "total done:\(totalCompleted) fail:\(totalFailed)"
        ]

        let currentNetwork = latestNetworkTile.map { "net:\(Self.tileDescription($0))" }
        let currentParsing = latestParsingTile.map { "parse:\(Self.tileDescription($0))" }
        let current = [currentNetwork, currentParsing].compactMap { $0 }.joined(separator: " ")
        if current.isEmpty == false {
            output.append("current \(current)")
        }
        if let latestFailure {
            output.append("last failure: \(latestFailure)")
        }
        if let timingLine = Self.parseLayerTimingLine(tile: latestParseLayerTimingTile,
                                                      timings: latestParseLayerTimings) {
            output.append(timingLine)
        }
        return output
    }

    private static func tileDescription(_ tile: Tile) -> String {
        "z\(tile.z)/\(tile.x)/\(tile.y)"
    }

    private static func parseLayerTimingLine(tile: Tile?, timings: [TileParseLayerTiming]) -> String? {
        guard let tile, timings.isEmpty == false else {
            return nil
        }
        let items = timings
            .filter { $0.duration > 0 }
            .sorted { lhs, rhs in
                if lhs.duration != rhs.duration {
                    return lhs.duration > rhs.duration
                }
                return lhs.layerName < rhs.layerName
            }
            .prefix(3)
            .map { "\($0.layerName) \(Self.millisecondsDescription($0.duration))" }
        guard items.isEmpty == false else {
            return nil
        }
        return "parse layers \(tileDescription(tile)): \(items.joined(separator: ", "))"
    }

    private static func millisecondsDescription(_ duration: TimeInterval) -> String {
        let milliseconds = Int((duration * 1000).rounded())
        return "\(milliseconds)ms"
    }
}

final class TileLoadingStatusReporter {
    private struct PhaseCounters {
        var inFlight = 0
        var completed = 0
        var failed = 0

        var snapshot: TileLoadingPhaseSnapshot {
            TileLoadingPhaseSnapshot(inFlight: inFlight,
                                     completed: completed,
                                     failed: failed)
        }
    }

    private struct TileRecord {
        var status: TileLoadingTileStatus
        var progress: Double
        var detail: String
        var preparationStages: [TilePreparationStageSnapshot] = []
        var stageStartTimes: [String: TimeInterval] = [:]
        var sequence: UInt64
    }

    private let queue = DispatchQueue(label: "ImmersiveMap.TileLoadingStatusReporter")
    private let now: () -> TimeInterval
    private var requested = 0
    private var deduplicated = 0
    private var activeLoads = 0
    private var activeLoadTiles: Set<Tile> = []
    private var scheduled = 0
    private var network = PhaseCounters()
    private var parsing = PhaseCounters()
    private var totalCompleted = 0
    private var totalFailed = 0
    private var networkBytes = 0
    private var activeNetworkTiles: Set<Tile> = []
    private var activeParsingTiles: Set<Tile> = []
    private var latestNetworkTile: Tile?
    private var latestParsingTile: Tile?
    private var latestFailure: String?
    private var latestParseLayerTimingTile: Tile?
    private var latestParseLayerTimings: [TileParseLayerTiming] = []
    private var currentDemand: Set<Tile> = []
    private var displayedTiles: Set<Tile> = []
    private var tileRecords: [Tile: TileRecord] = [:]
    private var recentPreparationStagesByTile: [Tile: [TilePreparationStageSnapshot]] = [:]
    private var sequence: UInt64 = 0

    init(now: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.now = now
    }

    func recordDemand(input: Int, deduplicated: Int, tiles: [Tile]) {
        queue.sync {
            self.requested = input
            self.deduplicated = deduplicated
            currentDemand = Set(tiles)
            pruneInactiveStaleTiles()
        }
    }

    func recordDisplayedTiles(_ tiles: [Tile]) {
        queue.sync {
            displayedTiles = Set(tiles)
            for tile in tiles {
                guard shouldCreateDisplayedRecord(for: tile) else {
                    continue
                }
                restoreRecentPreparationStages(for: tile)
                updateTile(tile,
                           status: .ready,
                           progress: 1,
                           detail: "displayed")
            }
            pruneInactiveStaleTiles()
        }
    }

    func recordLoadScheduled(tile: Tile) {
        queue.sync {
            scheduled += 1
            updateTile(tile,
                       status: .queued,
                       progress: 0.1,
                       detail: "queued")
        }
    }

    func recordLoadStarted(tile: Tile) {
        queue.sync {
            activeLoadTiles.insert(tile)
            activeLoads = activeLoadTiles.count
            updateTile(tile,
                       status: .loading,
                       progress: 0.35,
                       detail: "network")
        }
    }

    func recordLoadCompleted(tile: Tile) {
        queue.sync {
            activeLoadTiles.remove(tile)
            activeLoads = activeLoadTiles.count
            totalCompleted += 1
            appendInstantStage("ready", for: tile)
            storeRecentPreparationStages(for: tile)
            updateTile(tile,
                       status: .ready,
                       progress: 1,
                       detail: "ready")
            pruneInactiveStaleTiles()
        }
    }

    func recordLoadFailed(tile: Tile, reason: String) {
        queue.sync {
            activeLoadTiles.remove(tile)
            activeLoads = activeLoadTiles.count
            totalFailed += 1
            latestFailure = reason
            updateTile(tile,
                       status: .failed,
                       progress: 1,
                       detail: reason)
            pruneInactiveStaleTiles()
        }
    }

    func recordLoadsCancelled(tiles: [Tile]) {
        let cancelledTiles = Set(tiles)
        queue.sync {
            requested = 0
            deduplicated = 0
            currentDemand.removeAll()

            activeLoadTiles.subtract(cancelledTiles)
            activeLoads = activeLoadTiles.count
            activeNetworkTiles.subtract(cancelledTiles)
            network.inFlight = activeNetworkTiles.count
            activeParsingTiles.subtract(cancelledTiles)
            parsing.inFlight = activeParsingTiles.count

            for tile in cancelledTiles {
                tileRecords.removeValue(forKey: tile)
                if displayedTiles.contains(tile) {
                    updateTile(tile,
                               status: .ready,
                               progress: 1,
                               detail: "displayed")
                }
            }
            refreshLatestNetworkTile()
            refreshLatestParsingTile()
            pruneInactiveStaleTiles()
        }
    }

    func recordNetworkStarted(tile: Tile) {
        queue.sync {
            network.inFlight += 1
            activeNetworkTiles.insert(tile)
            latestNetworkTile = tile
            startStage("network", for: tile)
            updateTile(tile,
                       status: .loading,
                       progress: 0.35,
                       detail: "network")
        }
    }

    func recordNetworkSucceeded(tile: Tile, bytes: Int) {
        queue.sync {
            network.inFlight = max(0, network.inFlight - 1)
            network.completed += 1
            networkBytes += bytes
            activeNetworkTiles.remove(tile)
            finishStage("network", for: tile)
            updateTile(tile,
                       status: .loading,
                       progress: 0.55,
                       detail: "\(bytes) bytes")
            refreshLatestNetworkTile()
        }
    }

    func recordNetworkFailed(tile: Tile, reason: String) {
        queue.sync {
            network.inFlight = max(0, network.inFlight - 1)
            network.failed += 1
            activeNetworkTiles.remove(tile)
            latestFailure = reason
            finishStage("network", for: tile)
            updateTile(tile,
                       status: .failed,
                       progress: 1,
                       detail: reason)
            refreshLatestNetworkTile()
        }
    }

    func recordParsingStarted(tile: Tile) {
        queue.sync {
            parsing.inFlight += 1
            activeParsingTiles.insert(tile)
            latestParsingTile = tile
            startStage("parse", for: tile)
            updateTile(tile,
                       status: .parsing,
                       progress: 0.7,
                       detail: "parse")
        }
    }

    func recordParsingSucceeded(tile: Tile, layerTimings: [TileParseLayerTiming] = []) {
        queue.sync {
            parsing.inFlight = max(0, parsing.inFlight - 1)
            parsing.completed += 1
            activeParsingTiles.remove(tile)
            latestParseLayerTimingTile = tile
            latestParseLayerTimings = Self.sortedLayerTimings(layerTimings)
            finishStage("parse", for: tile, layerTimings: latestParseLayerTimings)
            updateTile(tile,
                       status: .parsing,
                       progress: 0.85,
                       detail: "materialize")
            refreshLatestParsingTile()
        }
    }

    func recordParsingFailed(tile: Tile, reason: String) {
        queue.sync {
            parsing.inFlight = max(0, parsing.inFlight - 1)
            parsing.failed += 1
            activeParsingTiles.remove(tile)
            latestFailure = reason
            finishStage("parse", for: tile)
            updateTile(tile,
                       status: .failed,
                       progress: 1,
                       detail: reason)
            refreshLatestParsingTile()
        }
    }

    func recordMaterializationStarted(tile: Tile) {
        queue.sync {
            startStage("materialize", for: tile)
            updateTile(tile,
                       status: .parsing,
                       progress: 0.9,
                       detail: "materialize")
        }
    }

    func recordMaterializationSucceeded(tile: Tile) {
        queue.sync {
            finishStage("materialize", for: tile)
            updateTile(tile,
                       status: .parsing,
                       progress: 0.95,
                       detail: "materialized")
        }
    }

    func recordMaterializationFailed(tile: Tile, reason: String) {
        queue.sync {
            finishStage("materialize", for: tile)
            updateTile(tile,
                       status: .parsing,
                       progress: 0.95,
                       detail: reason)
        }
    }

    func snapshot() -> TileLoadingStatusSnapshot {
        queue.sync {
            let tiles = tileRecords
                .filter { tile, record in
                    shouldIncludeTile(tile, record: record)
                }
                .map { tile, record in
                    (
                        snapshot: TileLoadingStatusTileSnapshot(tile: tile,
                                                                status: record.status,
                                                                progress: record.progress,
                                                                detail: record.detail,
                                                                preparationStages: record.preparationStages),
                        sequence: record.sequence
                    )
                }
                .sorted(by: Self.shouldPlaceTileBefore)
                .map(\.snapshot)
            return TileLoadingStatusSnapshot(requested: requested,
                                             deduplicated: deduplicated,
                                             activeLoads: activeLoads,
                                             scheduled: scheduled,
                                             network: network.snapshot,
                                             parsing: parsing.snapshot,
                                             totalCompleted: totalCompleted,
                                             totalFailed: totalFailed,
                                             networkBytes: networkBytes,
                                             latestNetworkTile: latestNetworkTile,
                                             latestParsingTile: latestParsingTile,
                                             latestFailure: latestFailure,
                                             latestParseLayerTimingTile: latestParseLayerTimingTile,
                                             latestParseLayerTimings: latestParseLayerTimings,
                                             tiles: Array(tiles))
        }
    }

    private func updateTile(_ tile: Tile,
                            status: TileLoadingTileStatus,
                            progress: Double,
                            detail: String) {
        sequence &+= 1
        var record = tileRecords[tile] ?? TileRecord(status: status,
                                                     progress: progress,
                                                     detail: detail,
                                                     sequence: sequence)
        record.status = status
        record.progress = min(max(progress, 0), 1)
        record.detail = detail
        record.sequence = sequence
        tileRecords[tile] = record
    }

    private func startStage(_ name: String, for tile: Tile) {
        var record = tileRecords[tile] ?? TileRecord(status: .queued,
                                                     progress: 0.1,
                                                     detail: "queued",
                                                     sequence: sequence)
        record.stageStartTimes[name] = now()
        tileRecords[tile] = record
    }

    private func finishStage(_ name: String,
                             for tile: Tile,
                             layerTimings: [TileParseLayerTiming] = []) {
        var record = tileRecords[tile] ?? TileRecord(status: .queued,
                                                     progress: 0.1,
                                                     detail: "queued",
                                                     sequence: sequence)
        let duration = record.stageStartTimes.removeValue(forKey: name).map { max(0, now() - $0) }
        record.preparationStages.removeAll { $0.name == name }
        record.preparationStages.append(TilePreparationStageSnapshot(name: name,
                                                                     duration: duration,
                                                                     layerTimings: layerTimings))
        tileRecords[tile] = record
    }

    private func appendInstantStage(_ name: String, for tile: Tile) {
        var record = tileRecords[tile] ?? TileRecord(status: .queued,
                                                     progress: 0.1,
                                                     detail: "queued",
                                                     sequence: sequence)
        record.preparationStages.removeAll { $0.name == name }
        record.preparationStages.append(TilePreparationStageSnapshot(name: name,
                                                                     duration: nil))
        tileRecords[tile] = record
    }

    private func storeRecentPreparationStages(for tile: Tile) {
        guard let stages = tileRecords[tile]?.preparationStages,
              stages.isEmpty == false else {
            return
        }
        recentPreparationStagesByTile[tile] = stages
        pruneRecentPreparationStages()
    }

    private func restoreRecentPreparationStages(for tile: Tile) {
        guard let stages = recentPreparationStagesByTile[tile],
              stages.isEmpty == false else {
            return
        }
        var record = tileRecords[tile] ?? TileRecord(status: .ready,
                                                     progress: 1,
                                                     detail: "displayed",
                                                     sequence: sequence)
        record.preparationStages = stages
        tileRecords[tile] = record
    }

    private func pruneRecentPreparationStages() {
        let retainedTiles = currentDemand.union(displayedTiles).union(activeNetworkTiles).union(activeParsingTiles)
        let maximumRecentPreparationStageCount = 256
        if recentPreparationStagesByTile.count <= maximumRecentPreparationStageCount {
            return
        }
        recentPreparationStagesByTile = recentPreparationStagesByTile.filter { retainedTiles.contains($0.key) }
    }

    private func pruneInactiveStaleTiles() {
        tileRecords = tileRecords.filter { tile, record in
            shouldIncludeTile(tile, record: record)
        }
    }

    private func refreshLatestNetworkTile() {
        latestNetworkTile = latestActiveTile(in: activeNetworkTiles)
    }

    private func refreshLatestParsingTile() {
        latestParsingTile = latestActiveTile(in: activeParsingTiles)
    }

    private func latestActiveTile(in tiles: Set<Tile>) -> Tile? {
        tiles.max { lhs, rhs in
            let lhsSequence = tileRecords[lhs]?.sequence ?? 0
            let rhsSequence = tileRecords[rhs]?.sequence ?? 0
            if lhsSequence != rhsSequence {
                return lhsSequence < rhsSequence
            }
            if lhs.z != rhs.z {
                return lhs.z < rhs.z
            }
            if lhs.x != rhs.x {
                return lhs.x > rhs.x
            }
            return lhs.y > rhs.y
        }
    }

    private func shouldIncludeTile(_ tile: Tile, record: TileRecord) -> Bool {
        currentDemand.contains(tile) || displayedTiles.contains(tile) || Self.isActiveResourceStatus(record.status)
    }

    private func shouldCreateDisplayedRecord(for tile: Tile) -> Bool {
        guard let record = tileRecords[tile] else {
            return true
        }
        return Self.isActiveResourceStatus(record.status) == false
    }

    private static func isActiveResourceStatus(_ status: TileLoadingTileStatus) -> Bool {
        switch status {
        case .loading, .parsing:
            return true
        case .queued, .ready, .failed:
            return false
        }
    }

    private static func sortedLayerTimings(_ timings: [TileParseLayerTiming]) -> [TileParseLayerTiming] {
        timings
            .filter { $0.duration > 0 }
            .sorted { lhs, rhs in
                if lhs.duration != rhs.duration {
                    return lhs.duration > rhs.duration
                }
                return lhs.layerName < rhs.layerName
            }
    }

    private static func shouldPlaceTileBefore(
        _ lhs: (snapshot: TileLoadingStatusTileSnapshot, sequence: UInt64),
        _ rhs: (snapshot: TileLoadingStatusTileSnapshot, sequence: UInt64)
    ) -> Bool {
        let lhsPriority = priority(lhs.snapshot.status)
        let rhsPriority = priority(rhs.snapshot.status)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }
        if lhs.sequence != rhs.sequence {
            return lhs.sequence > rhs.sequence
        }
        if lhs.snapshot.tile.z != rhs.snapshot.tile.z {
            return lhs.snapshot.tile.z > rhs.snapshot.tile.z
        }
        if lhs.snapshot.tile.x != rhs.snapshot.tile.x {
            return lhs.snapshot.tile.x < rhs.snapshot.tile.x
        }
        return lhs.snapshot.tile.y < rhs.snapshot.tile.y
    }

    private static func priority(_ status: TileLoadingTileStatus) -> Int {
        switch status {
        case .loading:
            return 0
        case .parsing:
            return 1
        case .queued:
            return 2
        case .failed:
            return 3
        case .ready:
            return 4
        }
    }
}
