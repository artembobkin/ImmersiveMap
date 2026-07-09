// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

struct TileTraceRecorderSnapshot: Equatable {
    let isRecording: Bool
    let fileURL: URL?
}

enum TileTraceValue {
    case bool(Bool)
    case double(Double)
    case int(Int)
    case string(String)
    case tile(Tile)
    case url(String)

    var jsonValue: Any {
        switch self {
        case let .bool(value):
            return value
        case let .double(value):
            return value
        case let .int(value):
            return value
        case let .string(value):
            return value
        case let .tile(tile):
            return "\(tile.z)/\(tile.x)/\(tile.y)"
        case let .url(value):
            return TileTraceURLRedactor.redact(value)
        }
    }
}

struct TileTraceEvent {
    let name: String
    let frameIndex: UInt64?
    let fields: [String: TileTraceValue]

    static func event(_ name: String,
                      frameIndex: UInt64? = nil,
                      fields: [String: TileTraceValue] = [:]) -> TileTraceEvent {
        TileTraceEvent(name: name,
                       frameIndex: frameIndex,
                       fields: fields)
    }
}

extension TileTraceEvent {
    static func tileStoreRequest(frameIndex: UInt64?,
                                 demanded: Int,
                                 ready: Int,
                                 requested: Int) -> TileTraceEvent {
        .event("tile_store_request",
               frameIndex: frameIndex,
               fields: [
                   "demanded": .int(demanded),
                   "ready": .int(ready),
                   "requested": .int(requested)
               ])
    }

    static func tilePrepareStart(_ tile: Tile) -> TileTraceEvent {
        .event("tile_prepare_start", fields: ["tile": .tile(tile)])
    }

    static func tilePrepareSuccess(_ tile: Tile,
                                   layerTimings: [TileParseLayerTiming] = []) -> TileTraceEvent {
        var fields: [String: TileTraceValue] = ["tile": .tile(tile)]
        let timings = parseLayerTimingsDescription(layerTimings)
        if timings.isEmpty == false {
            fields["parseLayerTimings"] = .string(timings)
        }
        return .event("tile_prepare_success", fields: fields)
    }

    static func tilePrepareFailed(_ tile: Tile, error: Error) -> TileTraceEvent {
        .event("tile_prepare_failed",
               fields: [
                   "tile": .tile(tile),
                   "error": .string(String(describing: error))
               ])
    }

    static func tileMaterializeSuccess(_ tile: Tile) -> TileTraceEvent {
        .event("tile_materialize_success", fields: ["tile": .tile(tile)])
    }

    static func tileMaterializeStart(_ tile: Tile) -> TileTraceEvent {
        .event("tile_materialize_start", fields: ["tile": .tile(tile)])
    }

    static func tileMaterializeFailed(_ tile: Tile) -> TileTraceEvent {
        .event("tile_materialize_failed", fields: ["tile": .tile(tile)])
    }

    static func tileMemoryCacheGet(_ tile: Tile,
                                   hit: Bool,
                                   knownCost: Int?,
                                   trackedCost: Int,
                                   trackedCount: Int,
                                   costLimit: Int) -> TileTraceEvent {
        var fields: [String: TileTraceValue] = [
            "tile": .tile(tile),
            "hit": .bool(hit),
            "trackedCost": .int(trackedCost),
            "trackedCount": .int(trackedCount),
            "costLimit": .int(costLimit)
        ]
        if let knownCost {
            fields["knownCost"] = .int(knownCost)
        }
        return .event("tile_memory_cache_get", fields: fields)
    }

    static func tileMemoryCacheSet(_ tile: Tile,
                                   cost: Int,
                                   replacedCost: Int?,
                                   trackedCost: Int,
                                   trackedCount: Int,
                                   costLimit: Int) -> TileTraceEvent {
        var fields: [String: TileTraceValue] = [
            "tile": .tile(tile),
            "cost": .int(cost),
            "trackedCost": .int(trackedCost),
            "trackedCount": .int(trackedCount),
            "costLimit": .int(costLimit)
        ]
        if let replacedCost {
            fields["replacedCost"] = .int(replacedCost)
        }
        return .event("tile_memory_cache_set", fields: fields)
    }

    static func tileMemoryCacheEvict(_ tile: Tile,
                                     cost: Int?,
                                     trackedCost: Int,
                                     trackedCount: Int,
                                     costLimit: Int) -> TileTraceEvent {
        var fields: [String: TileTraceValue] = [
            "tile": .tile(tile),
            "trackedCost": .int(trackedCost),
            "trackedCount": .int(trackedCount),
            "costLimit": .int(costLimit)
        ]
        if let cost {
            fields["cost"] = .int(cost)
        }
        return .event("tile_memory_cache_evict", fields: fields)
    }

    static func tileSchedulerRequest(input: Int, deduplicated: Int) -> TileTraceEvent {
        .event("tile_scheduler_request",
               fields: [
                   "input": .int(input),
                   "deduplicated": .int(deduplicated)
               ])
    }

    static func tileSchedulerAlreadyLoading(_ tile: Tile) -> TileTraceEvent {
        .event("tile_scheduler_already_loading", fields: ["tile": .tile(tile)])
    }

    static func tileSchedulerRetryBlocked(_ tile: Tile) -> TileTraceEvent {
        .event("tile_scheduler_retry_blocked", fields: ["tile": .tile(tile)])
    }

    static func tileSchedulerEnqueued(_ tile: Tile, inFlight: Int) -> TileTraceEvent {
        .event("tile_scheduler_enqueued",
               fields: [
                   "tile": .tile(tile),
                   "inFlight": .int(inFlight)
               ])
    }

    static func tileLoadScheduled(_ tile: Tile, inFlight: Int) -> TileTraceEvent {
        .event("tile_load_scheduled",
               fields: [
                   "tile": .tile(tile),
                   "inFlight": .int(inFlight)
               ])
    }

    static func tileLoadStart(_ tile: Tile) -> TileTraceEvent {
        .event("tile_load_start", fields: ["tile": .tile(tile)])
    }

    static func tileDownloadSuccess(_ tile: Tile, bytes: Int) -> TileTraceEvent {
        .event("tile_download_success",
               fields: [
                   "tile": .tile(tile),
                   "bytes": .int(bytes)
               ])
    }

    static func tileDownloadFailed(_ tile: Tile, reason: String) -> TileTraceEvent {
        .event("tile_download_failed",
               fields: [
                   "tile": .tile(tile),
                   "reason": .string(reason)
               ])
    }

    static func tileLoadSuccess(_ tile: Tile, source: String) -> TileTraceEvent {
        .event("tile_load_success",
               fields: [
                   "tile": .tile(tile),
                   "source": .string(source)
               ])
    }

    static func tileLoadFailed(_ tile: Tile, reason: String) -> TileTraceEvent {
        .event("tile_load_failed",
               fields: [
                   "tile": .tile(tile),
                   "reason": .string(reason)
               ])
    }

    static func tileDemandUpdate(frameIndex: UInt64,
                                 visible: Int,
                                 preprocessed: Int,
                                 demanded: Int,
                                 ready: Int,
                                 requested: Int,
                                 rendered: Int,
                                 placementChanged: Bool,
                                 placementVersion: UInt64,
                                 surface: String,
                                 lodExact: Int,
                                 lodCoarse: Int,
                                 lodRetained: Int) -> TileTraceEvent {
        .event("tile_demand_update",
               frameIndex: frameIndex,
               fields: [
                   "visible": .int(visible),
                   "preprocessed": .int(preprocessed),
                   "demanded": .int(demanded),
                   "ready": .int(ready),
                   "requested": .int(requested),
                   "rendered": .int(rendered),
                   "placementChanged": .bool(placementChanged),
                   "placementVersion": .int(Int(placementVersion)),
                   "surface": .string(surface),
                   "lodExact": .int(lodExact),
                   "lodCoarse": .int(lodCoarse),
                   "lodRetained": .int(lodRetained)
               ])
    }

    static func atlasTextureStage(frameIndex: UInt64,
                                  textureChanged: Bool,
                                  placementVersion: UInt64,
                                  plan: GlobeAtlasPlan,
                                  surface: String) -> TileTraceEvent {
        .event("atlas_texture_stage",
               frameIndex: frameIndex,
               fields: [
                   "textureChanged": .bool(textureChanged),
                   "placementVersion": .int(Int(placementVersion)),
                   "allocations": .int(plan.allocations.count),
                   "pages": .int(plan.pageSummaries.count),
                   "downgraded": .int(plan.downgradedAllocationCount),
                   "skipped": .int(plan.skippedAllocationCount),
                   "surface": .string(surface)
               ])
    }

    static func atlasTextureRedraw(frameIndex: UInt64,
                                   plan: GlobeAtlasPlan,
                                   encodedPages: Int) -> TileTraceEvent {
        .event("atlas_texture_redraw",
               frameIndex: frameIndex,
               fields: [
                   "allocations": .int(plan.allocations.count),
                   "pages": .int(encodedPages),
                   "downgraded": .int(plan.downgradedAllocationCount),
                   "skipped": .int(plan.skippedAllocationCount)
               ])
    }

    static func atlasPlanReused(frameIndex: UInt64,
                                placementVersion: UInt64,
                                plan: GlobeAtlasPlan,
                                surface: String) -> TileTraceEvent {
        .event("atlas_plan_reused",
               frameIndex: frameIndex,
               fields: [
                   "placementVersion": .int(Int(placementVersion)),
                   "allocations": .int(plan.allocations.count),
                   "pages": .int(plan.pageSummaries.count),
                   "surface": .string(surface)
               ])
    }

    static func atlasPlanRebuilt(frameIndex: UInt64,
                                 placementVersion: UInt64,
                                 plan: GlobeAtlasPlan,
                                 surface: String) -> TileTraceEvent {
        .event("atlas_plan_rebuilt",
               frameIndex: frameIndex,
               fields: [
                   "placementVersion": .int(Int(placementVersion)),
                   "allocations": .int(plan.allocations.count),
                   "pages": .int(plan.pageSummaries.count),
                   "downgraded": .int(plan.downgradedAllocationCount),
                   "skipped": .int(plan.skippedAllocationCount),
                   "surface": .string(surface)
               ])
    }

    static func tileLoadingStatusSnapshot(frameIndex: UInt64,
                                          snapshot: TileLoadingStatusSnapshot) -> TileTraceEvent {
        var fields: [String: TileTraceValue] = [
            "requested": .int(snapshot.requested),
            "deduplicated": .int(snapshot.deduplicated),
            "activeLoads": .int(snapshot.activeLoads),
            "scheduled": .int(snapshot.scheduled),
            "networkInFlight": .int(snapshot.network.inFlight),
            "networkCompleted": .int(snapshot.network.completed),
            "networkFailed": .int(snapshot.network.failed),
            "parseInFlight": .int(snapshot.parsing.inFlight),
            "parseCompleted": .int(snapshot.parsing.completed),
            "parseFailed": .int(snapshot.parsing.failed),
            "totalCompleted": .int(snapshot.totalCompleted),
            "totalFailed": .int(snapshot.totalFailed),
            "networkBytes": .int(snapshot.networkBytes)
        ]
        if let latestNetworkTile = snapshot.latestNetworkTile {
            fields["latestNetworkTile"] = .tile(latestNetworkTile)
        }
        if let latestParsingTile = snapshot.latestParsingTile {
            fields["latestParsingTile"] = .tile(latestParsingTile)
        }
        if let latestFailure = snapshot.latestFailure {
            fields["latestFailure"] = .string(latestFailure)
        }
        let tiles = tileStatusDescription(snapshot.tiles)
        if tiles.isEmpty == false {
            fields["tiles"] = .string(tiles)
        }
        return .event("tile_loading_status_snapshot",
                      frameIndex: frameIndex,
                      fields: fields)
    }

    private static func parseLayerTimingsDescription(_ timings: [TileParseLayerTiming]) -> String {
        timings
            .filter { $0.duration > 0 }
            .sorted { lhs, rhs in
                if lhs.duration != rhs.duration {
                    return lhs.duration > rhs.duration
                }
                return lhs.layerName < rhs.layerName
            }
            .map { timing in
                let milliseconds = Int((timing.duration * 1000).rounded())
                return "\(timing.layerName):\(milliseconds)ms"
            }
            .joined(separator: ",")
    }

    private static func tileStatusDescription(_ tiles: [TileLoadingStatusTileSnapshot]) -> String {
        tiles
            .map { tile in
                "\(tile.tile.z)/\(tile.tile.x)/\(tile.tile.y):\(tileStatusDescription(tile.status)):\(tile.detail)"
            }
            .joined(separator: ";")
    }

    private static func tileStatusDescription(_ status: TileLoadingTileStatus) -> String {
        switch status {
        case .queued:
            return "queued"
        case .loading:
            return "loading"
        case .parsing:
            return "parsing"
        case .ready:
            return "ready"
        case .failed:
            return "failed"
        }
    }
}

final class TileTraceRecorder {
    private let fileManager: FileManager
    private let directoryURL: URL
    private let now: () -> Date
    private let queue = DispatchQueue(label: "ImmersiveMap.TileTraceRecorder")
    private let stateLock = NSLock()

    private var fileHandle: FileHandle?
    private var currentFileURL: URL?
    private var isRecordingFlag = false

    init(fileManager: FileManager = .default,
         directoryURL: URL? = nil,
         now: @escaping () -> Date = Date.init) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL(fileManager: fileManager)
        self.now = now
    }

    @discardableResult
    func startRecording() -> URL? {
        queue.sync {
            if fileHandle != nil {
                return currentFileURL
            }

            do {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                let fileURL = directoryURL.appendingPathComponent(makeFileName(for: now()))
                fileManager.createFile(atPath: fileURL.path, contents: nil)
                let handle = try FileHandle(forWritingTo: fileURL)
                fileHandle = handle
                currentFileURL = fileURL
                setRecordingFlag(true)
                return fileURL
            } catch {
                fileHandle = nil
                currentFileURL = nil
                setRecordingFlag(false)
                return nil
            }
        }
    }

    func stopRecording() {
        queue.sync {
            guard let fileHandle else { return }
            try? fileHandle.synchronize()
            try? fileHandle.close()
            self.fileHandle = nil
            setRecordingFlag(false)
        }
    }

    func snapshot() -> TileTraceRecorderSnapshot {
        queue.sync {
            TileTraceRecorderSnapshot(isRecording: fileHandle != nil,
                                      fileURL: currentFileURL)
        }
    }

    func record(_ event: TileTraceEvent) {
        guard isRecording else { return }
        let timestamp = now()
        queue.async { [weak self] in
            guard let self,
                  let fileHandle else {
                return
            }

            guard let line = makeJSONLine(event: event, timestamp: timestamp),
                  let data = line.data(using: .utf8) else {
                return
            }
            fileHandle.write(data)
        }
    }

    private var isRecording: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isRecordingFlag
    }

    private func setRecordingFlag(_ isRecording: Bool) {
        stateLock.lock()
        isRecordingFlag = isRecording
        stateLock.unlock()
    }

    private func makeJSONLine(event: TileTraceEvent, timestamp: Date) -> String? {
        var object: [String: Any] = [
            "t": timestamp.timeIntervalSince1970,
            "event": event.name
        ]
        if let frameIndex = event.frameIndex {
            object["frame"] = Int(frameIndex)
        }
        for key in event.fields.keys.sorted() {
            object[key] = event.fields[key]?.jsonValue
        }

        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json + "\n"
    }

    private func makeFileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "immersive-map-tile-trace-\(formatter.string(from: date)).jsonl"
    }

    private static func defaultDirectoryURL(fileManager: FileManager) -> URL {
        if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            return documents.appendingPathComponent("ImmersiveMapDebugLogs", isDirectory: true)
        }
        return fileManager.temporaryDirectory.appendingPathComponent("ImmersiveMapDebugLogs", isDirectory: true)
    }
}

enum TileTraceURLRedactor {
    private static let sensitiveQueryNames: Set<String> = [
        "access_token",
        "apikey",
        "api_key",
        "authorization",
        "auth",
        "key",
        "password",
        "token"
    ]

    static func redact(_ value: String) -> String {
        guard var components = URLComponents(string: value),
              let queryItems = components.queryItems,
              queryItems.isEmpty == false else {
            return value
        }

        components.queryItems = queryItems.map { item in
            guard sensitiveQueryNames.contains(item.name.lowercased()) else {
                return item
            }
            return URLQueryItem(name: item.name, value: "REDACTED")
        }
        return components.string ?? value
    }
}
