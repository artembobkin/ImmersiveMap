// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Foundation
import XCTest

final class TileTraceRecorderTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImmersiveMapTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        try super.tearDownWithError()
    }

    func testRecordsJsonLinesOnlyWhileRecording() throws {
        let recorder = TileTraceRecorder(directoryURL: temporaryDirectory,
                                         now: { Date(timeIntervalSince1970: 1_000) })

        recorder.record(.event("before_start", frameIndex: 1))
        let fileURL = try XCTUnwrap(recorder.startRecording())
        recorder.record(.event("tile_request", frameIndex: 2, fields: [
            "tile": .string("1/0/0"),
            "requested": .int(4),
            "ready": .int(1)
        ]))
        recorder.stopRecording()
        recorder.record(.event("after_stop", frameIndex: 3))

        let lines = try readJSONLines(fileURL)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0]["event"] as? String, "tile_request")
        XCTAssertEqual(lines[0]["frame"] as? Int, 2)
        XCTAssertEqual(lines[0]["tile"] as? String, "1/0/0")
        XCTAssertEqual(lines[0]["requested"] as? Int, 4)
        XCTAssertEqual(lines[0]["ready"] as? Int, 1)
    }

    func testRedactsSensitiveURLQueryValues() throws {
        let recorder = TileTraceRecorder(directoryURL: temporaryDirectory,
                                         now: { Date(timeIntervalSince1970: 1_000) })
        let fileURL = try XCTUnwrap(recorder.startRecording())

        recorder.record(.event("download", fields: [
            "url": .url("https://example.com/tiles/1/0/0.mvt?access_token=secret-token&style=dark&token=other-secret")
        ]))
        recorder.stopRecording()

        let line = try XCTUnwrap(readJSONLines(fileURL).first)
        XCTAssertEqual(line["url"] as? String,
                       "https://example.com/tiles/1/0/0.mvt?access_token=REDACTED&style=dark&token=REDACTED")
    }

    func testSnapshotReflectsRecordingStateAndFileURL() {
        let recorder = TileTraceRecorder(directoryURL: temporaryDirectory,
                                         now: { Date(timeIntervalSince1970: 1_000) })

        XCTAssertFalse(recorder.snapshot().isRecording)
        let fileURL = recorder.startRecording()
        XCTAssertEqual(recorder.snapshot(), TileTraceRecorderSnapshot(isRecording: true, fileURL: fileURL))
        recorder.stopRecording()
        XCTAssertEqual(recorder.snapshot(), TileTraceRecorderSnapshot(isRecording: false, fileURL: fileURL))
    }

    func testRecordsWorkingSetDiagnosticEventsOnlyWhileRecording() throws {
        let recorder = TileTraceRecorder(directoryURL: temporaryDirectory,
                                         now: { Date(timeIntervalSince1970: 1_000) })

        recorder.record(.tileStoreLookup(Tile(x: 2, y: 3, z: 4),
                                         hit: false,
                                         residentCount: 0,
                                         residentBytes: 0))
        let fileURL = try XCTUnwrap(recorder.startRecording())
        recorder.record(.tileStoreInsert(Tile(x: 2, y: 3, z: 4),
                                         replaced: false,
                                         residentCount: 2,
                                         residentBytes: 76))
        recorder.record(.tileStoreLookup(Tile(x: 2, y: 3, z: 4),
                                         hit: true,
                                         residentCount: 2,
                                         residentBytes: 76))
        recorder.record(.tileStoreRelease(Tile(x: 2, y: 3, z: 4),
                                          reason: "left_demand",
                                          residentCount: 1,
                                          residentBytes: 12))
        recorder.record(.tileStoreRemoveAll(removedCount: 1, removedBytes: 12))
        recorder.stopRecording()

        let lines = try readJSONLines(fileURL)
        XCTAssertEqual(lines.map { $0["event"] as? String }, [
            "tile_store_insert",
            "tile_store_lookup",
            "tile_store_release",
            "tile_store_remove_all"
        ])
        XCTAssertEqual(lines[0]["tile"] as? String, "4/2/3")
        XCTAssertEqual(lines[0]["replaced"] as? Bool, false)
        XCTAssertEqual(lines[0]["residentBytes"] as? Int, 76)
        XCTAssertEqual(lines[1]["hit"] as? Bool, true)
        XCTAssertEqual(lines[2]["reason"] as? String, "left_demand")
        XCTAssertEqual(lines[2]["residentCount"] as? Int, 1)
        XCTAssertEqual(lines[3]["removedCount"] as? Int, 1)
    }

    func testPrepareSuccessEventIncludesLayerTimings() throws {
        let recorder = TileTraceRecorder(directoryURL: temporaryDirectory,
                                         now: { Date(timeIntervalSince1970: 1_000) })
        let fileURL = try XCTUnwrap(recorder.startRecording())

        recorder.record(.tilePrepareSuccess(Tile(x: 8, y: 6, z: 4),
                                            layerTimings: [
                                                TileParseLayerTiming(layerName: "water", duration: 0.053),
                                                TileParseLayerTiming(layerName: "landcover", duration: 0.027)
                                            ]))
        recorder.stopRecording()

        let line = try XCTUnwrap(readJSONLines(fileURL).first)
        XCTAssertEqual(line["event"] as? String, "tile_prepare_success")
        XCTAssertEqual(line["tile"] as? String, "4/8/6")
        XCTAssertEqual(line["parseLayerTimings"] as? String, "water:53ms,landcover:27ms")
    }

    func testTileLoadingStatusSnapshotEventRecordsPreparationState() throws {
        let recorder = TileTraceRecorder(directoryURL: temporaryDirectory,
                                         now: { Date(timeIntervalSince1970: 1_000) })
        let fileURL = try XCTUnwrap(recorder.startRecording())

        recorder.record(.tileLoadingStatusSnapshot(
            frameIndex: 12,
            snapshot: TileLoadingStatusSnapshot(
                requested: 29,
                deduplicated: 29,
                activeLoads: 4,
                scheduled: 21,
                disk: TileLoadingPhaseSnapshot(inFlight: 1, completed: 20, failed: 4),
                network: TileLoadingPhaseSnapshot(inFlight: 0, completed: 21, failed: 0),
                parsing: TileLoadingPhaseSnapshot(inFlight: 3, completed: 18, failed: 0),
                totalCompleted: 17,
                totalFailed: 0,
                networkBytes: 1_490_922,
                latestDiskTile: nil,
                latestNetworkTile: nil,
                latestParsingTile: Tile(x: 8, y: 6, z: 4),
                latestFailure: nil,
                latestParseLayerTimingTile: Tile(x: 8, y: 6, z: 4),
                latestParseLayerTimings: [
                    TileParseLayerTiming(layerName: "water", duration: 0.053)
                ],
                tiles: [
                    TileLoadingStatusTileSnapshot(tile: Tile(x: 8, y: 6, z: 4),
                                                  status: .parsing,
                                                  progress: 0.9,
                                                  detail: "materialize")
                ]
            )
        ))
        recorder.stopRecording()

        let line = try XCTUnwrap(readJSONLines(fileURL).first)
        XCTAssertEqual(line["event"] as? String, "tile_loading_status_snapshot")
        XCTAssertEqual(line["frame"] as? Int, 12)
        XCTAssertEqual(line["activeLoads"] as? Int, 4)
        XCTAssertEqual(line["scheduled"] as? Int, 21)
        XCTAssertEqual(line["diskCompleted"] as? Int, 20)
        XCTAssertEqual(line["parseInFlight"] as? Int, 3)
        XCTAssertEqual(line["latestParsingTile"] as? String, "4/8/6")
        XCTAssertEqual(line["tiles"] as? String, "4/8/6:parsing:materialize")
    }

    private func readJSONLines(_ fileURL: URL) throws -> [[String: Any]] {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        return try content
            .split(separator: "\n")
            .map { line in
                let data = try XCTUnwrap(String(line).data(using: .utf8))
                let object = try JSONSerialization.jsonObject(with: data)
                return try XCTUnwrap(object as? [String: Any])
            }
    }
}
