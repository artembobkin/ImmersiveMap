// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation

struct BaseLabelTraceRecorderSnapshot: Equatable {
    let isRecording: Bool
    let fileURL: URL?
}

struct BaseLabelTraceOptions: Equatable {
    static let `default` = BaseLabelTraceOptions()

    var fullLabelFrameInterval: UInt64 = 30
    var fullLabelHotBucketThreshold: Int = 12
    var includesFullLabelsOnTopologyChange: Bool = false
    var maxHotBuckets: Int = 16
    var maxPendingEvents: Int = 2_048

    func shouldIncludeFullLabels(frameIndex: UInt64,
                                 baseTrackedTilesChanged: Bool,
                                 projectionChanged: Bool,
                                 maxHotBucketCount: Int) -> Bool {
        if maxHotBucketCount >= fullLabelHotBucketThreshold {
            return true
        }
        if fullLabelFrameInterval > 0,
           frameIndex % fullLabelFrameInterval == 0 {
            return true
        }
        if includesFullLabelsOnTopologyChange,
           baseTrackedTilesChanged || projectionChanged {
            return true
        }
        return false
    }
}

enum BaseLabelTraceValue {
    case bool(Bool)
    case double(Double)
    case int(Int)
    case string(String)
    case tile(Tile)

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
        }
    }
}

struct BaseLabelTraceEvent {
    let name: String
    let frameIndex: UInt64?
    let fields: [String: BaseLabelTraceValue]

    static func event(_ name: String,
                      frameIndex: UInt64? = nil,
                      fields: [String: BaseLabelTraceValue] = [:]) -> BaseLabelTraceEvent {
        BaseLabelTraceEvent(name: name,
                            frameIndex: frameIndex,
                            fields: fields)
    }

    static func baseLabelFrame(frameIndex: UInt64,
                               zoom: Double,
                               pitchDegrees: Double,
                               bearingDegrees: Double,
                               sourceTileCount: Int,
                               baseTrackedTilesChanged: Bool,
                               roadTrackedTilesChanged: Bool,
                               projectionChanged: Bool,
                               fullTileCount: Int,
                               reducedTileCount: Int,
                               minimalTileCount: Int,
                               activeLabelSpanCount: Int,
                               labelInputsCount: Int,
                               validLabelCount: Int,
                               duplicateLabelCount: Int,
                               retainedLabelCount: Int,
                               collisionVisibleCount: Int,
                               collisionHiddenCount: Int,
                               collisionUnknownCount: Int,
                               targetVisibleCount: Int,
                               horizonVisibleCount: Int,
                               fadeVisibleCount: Int,
                               fadeAnimatingCount: Int,
                               cycleActive: Bool,
                               cycleCursor: Int,
                               cycleGroupCount: Int,
                               cycleComplete: Bool,
                               labels: String?,
                               hotBuckets: String,
                               maxHotBucketCount: Int = 0,
                               droppedEventCount: Int = 0) -> BaseLabelTraceEvent {
        var fields: [String: BaseLabelTraceValue] = [
            "activeLabelSpanCount": .int(activeLabelSpanCount),
            "baseTrackedTilesChanged": .bool(baseTrackedTilesChanged),
            "bearingDegrees": .double(bearingDegrees),
            "collisionHiddenCount": .int(collisionHiddenCount),
            "collisionUnknownCount": .int(collisionUnknownCount),
            "collisionVisibleCount": .int(collisionVisibleCount),
            "cycleActive": .bool(cycleActive),
            "cycleComplete": .bool(cycleComplete),
            "cycleCursor": .int(cycleCursor),
            "cycleGroupCount": .int(cycleGroupCount),
            "duplicateLabelCount": .int(duplicateLabelCount),
            "fadeAnimatingCount": .int(fadeAnimatingCount),
            "fadeVisibleCount": .int(fadeVisibleCount),
            "fullTileCount": .int(fullTileCount),
            "horizonVisibleCount": .int(horizonVisibleCount),
            "hotBuckets": .string(hotBuckets),
            "labelInputsCount": .int(labelInputsCount),
            "labelsIncluded": .bool(labels != nil),
            "maxHotBucketCount": .int(maxHotBucketCount),
            "minimalTileCount": .int(minimalTileCount),
            "pitchDegrees": .double(pitchDegrees),
            "projectionChanged": .bool(projectionChanged),
            "reducedTileCount": .int(reducedTileCount),
            "retainedLabelCount": .int(retainedLabelCount),
            "roadTrackedTilesChanged": .bool(roadTrackedTilesChanged),
            "sourceTileCount": .int(sourceTileCount),
            "targetVisibleCount": .int(targetVisibleCount),
            "validLabelCount": .int(validLabelCount),
            "zoom": .double(zoom)
        ]
        fields["droppedEventCount"] = .int(droppedEventCount)
        if let labels {
            fields["labels"] = .string(labels)
        }
        return event("base_label_frame", frameIndex: frameIndex, fields: fields)
    }
}

final class BaseLabelTraceRecorder {
    let options: BaseLabelTraceOptions

    private let fileManager: FileManager
    private let directoryURL: URL
    private let now: () -> Date
    private let queue = DispatchQueue(label: "ImmersiveMap.BaseLabelTraceRecorder")
    private let stateLock = NSLock()

    private var fileHandle: FileHandle?
    private var currentFileURL: URL?
    private var isRecordingFlag = false
    private var pendingEventCount = 0
    private var droppedEventCount = 0

    init(options: BaseLabelTraceOptions = .default,
         fileManager: FileManager = .default,
         directoryURL: URL? = nil,
         now: @escaping () -> Date = Date.init) {
        self.options = options
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
                resetQueueCounters()
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

    func snapshot() -> BaseLabelTraceRecorderSnapshot {
        queue.sync {
            BaseLabelTraceRecorderSnapshot(isRecording: fileHandle != nil,
                                           fileURL: currentFileURL)
        }
    }

    var isRecordingActive: Bool {
        isRecording
    }

    var currentDroppedEventCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return droppedEventCount
    }

    func record(_ event: BaseLabelTraceEvent) {
        guard isRecording else { return }
        guard reservePendingEventSlot() else { return }
        let timestamp = now()
        queue.async { [weak self] in
            defer {
                self?.releasePendingEventSlot()
            }
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

    private func resetQueueCounters() {
        stateLock.lock()
        pendingEventCount = 0
        droppedEventCount = 0
        stateLock.unlock()
    }

    private func reservePendingEventSlot() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard pendingEventCount < options.maxPendingEvents else {
            droppedEventCount += 1
            return false
        }
        pendingEventCount += 1
        return true
    }

    private func releasePendingEventSlot() {
        stateLock.lock()
        pendingEventCount = max(0, pendingEventCount - 1)
        stateLock.unlock()
    }

    private func makeJSONLine(event: BaseLabelTraceEvent, timestamp: Date) -> String? {
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
        return "immersive-map-base-label-trace-\(formatter.string(from: date)).jsonl"
    }

    private static func defaultDirectoryURL(fileManager: FileManager) -> URL {
        if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            return documents.appendingPathComponent("ImmersiveMapDebugLogs", isDirectory: true)
        }
        return fileManager.temporaryDirectory.appendingPathComponent("ImmersiveMapDebugLogs", isDirectory: true)
    }
}
