// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import Foundation
import XCTest

final class BaseLabelTraceRecorderTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImmersiveMapBaseLabelTraceTests-\(UUID().uuidString)", isDirectory: true)
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
        let recorder = BaseLabelTraceRecorder(directoryURL: temporaryDirectory,
                                              now: { Date(timeIntervalSince1970: 1_000) })

        recorder.record(.event("before_start", frameIndex: 1))
        let fileURL = try XCTUnwrap(recorder.startRecording())
        recorder.record(.event("base_label_frame", frameIndex: 2, fields: [
            "activeLabelSpanCount": .int(12),
            "cycleActive": .bool(true),
            "cameraPitch": .double(75.0),
            "labels": .string("1:visible:1.00")
        ]))
        recorder.stopRecording()
        recorder.record(.event("after_stop", frameIndex: 3))

        let lines = try readJSONLines(fileURL)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0]["event"] as? String, "base_label_frame")
        XCTAssertEqual(lines[0]["frame"] as? Int, 2)
        XCTAssertEqual(lines[0]["activeLabelSpanCount"] as? Int, 12)
        XCTAssertEqual(lines[0]["cycleActive"] as? Bool, true)
        XCTAssertEqual(lines[0]["cameraPitch"] as? Double, 75.0)
        XCTAssertEqual(lines[0]["labels"] as? String, "1:visible:1.00")
    }

    func testSnapshotReflectsRecordingStateAndFileURL() {
        let recorder = BaseLabelTraceRecorder(directoryURL: temporaryDirectory,
                                              now: { Date(timeIntervalSince1970: 1_000) })

        XCTAssertFalse(recorder.isRecordingActive)
        XCTAssertFalse(recorder.snapshot().isRecording)
        let fileURL = recorder.startRecording()
        XCTAssertTrue(recorder.isRecordingActive)
        XCTAssertEqual(recorder.snapshot(), BaseLabelTraceRecorderSnapshot(isRecording: true, fileURL: fileURL))
        recorder.stopRecording()
        XCTAssertFalse(recorder.isRecordingActive)
        XCTAssertEqual(recorder.snapshot(), BaseLabelTraceRecorderSnapshot(isRecording: false, fileURL: fileURL))
    }

    func testBaseLabelFrameEventContainsFrameDiagnostics() throws {
        let recorder = BaseLabelTraceRecorder(directoryURL: temporaryDirectory,
                                              now: { Date(timeIntervalSince1970: 1_000) })
        let fileURL = try XCTUnwrap(recorder.startRecording())

        recorder.record(.baseLabelFrame(frameIndex: 42,
                                        zoom: 11.5,
                                        pitchDegrees: 75.0,
                                        bearingDegrees: 18.0,
                                        sourceTileCount: 12,
                                        baseTrackedTilesChanged: true,
                                        roadTrackedTilesChanged: false,
                                        projectionChanged: true,
                                        fullTileCount: 3,
                                        reducedTileCount: 5,
                                        minimalTileCount: 4,
                                        activeLabelSpanCount: 30,
                                        labelInputsCount: 28,
                                        validLabelCount: 24,
                                        duplicateLabelCount: 2,
                                        retainedLabelCount: 1,
                                        collisionVisibleCount: 9,
                                        collisionHiddenCount: 10,
                                        collisionUnknownCount: 9,
                                        targetVisibleCount: 8,
                                        horizonVisibleCount: 18,
                                        fadeVisibleCount: 7,
                                        fadeAnimatingCount: 3,
                                        cycleActive: true,
                                        cycleCursor: 256,
                                        cycleGroupCount: 1024,
                                        cycleComplete: false,
                                        labels: "0|42|cv=visible|a=1.00",
                                        hotBuckets: "4/2:8/3/2",
                                        maxHotBucketCount: 8,
                                        droppedEventCount: 3))
        recorder.stopRecording()

        let lines = try readJSONLines(fileURL)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0]["event"] as? String, "base_label_frame")
        XCTAssertEqual(lines[0]["frame"] as? Int, 42)
        XCTAssertEqual(lines[0]["zoom"] as? Double, 11.5)
        XCTAssertEqual(lines[0]["pitchDegrees"] as? Double, 75.0)
        XCTAssertEqual(lines[0]["baseTrackedTilesChanged"] as? Bool, true)
        XCTAssertEqual(lines[0]["fullTileCount"] as? Int, 3)
        XCTAssertEqual(lines[0]["collisionUnknownCount"] as? Int, 9)
        XCTAssertEqual(lines[0]["cycleGroupCount"] as? Int, 1024)
        XCTAssertEqual(lines[0]["labelsIncluded"] as? Bool, true)
        XCTAssertEqual(lines[0]["labels"] as? String, "0|42|cv=visible|a=1.00")
        XCTAssertEqual(lines[0]["hotBuckets"] as? String, "4/2:8/3/2")
        XCTAssertEqual(lines[0]["maxHotBucketCount"] as? Int, 8)
        XCTAssertEqual(lines[0]["droppedEventCount"] as? Int, 3)
    }

    func testBaseLabelFrameCanOmitFullLabelsForLightweightFrames() throws {
        let recorder = BaseLabelTraceRecorder(directoryURL: temporaryDirectory,
                                              now: { Date(timeIntervalSince1970: 1_000) })
        let fileURL = try XCTUnwrap(recorder.startRecording())

        recorder.record(.baseLabelFrame(frameIndex: 43,
                                        zoom: 11.5,
                                        pitchDegrees: 75.0,
                                        bearingDegrees: 18.0,
                                        sourceTileCount: 12,
                                        baseTrackedTilesChanged: true,
                                        roadTrackedTilesChanged: false,
                                        projectionChanged: true,
                                        fullTileCount: 3,
                                        reducedTileCount: 5,
                                        minimalTileCount: 4,
                                        activeLabelSpanCount: 30,
                                        labelInputsCount: 28,
                                        validLabelCount: 24,
                                        duplicateLabelCount: 2,
                                        retainedLabelCount: 1,
                                        collisionVisibleCount: 9,
                                        collisionHiddenCount: 10,
                                        collisionUnknownCount: 9,
                                        targetVisibleCount: 8,
                                        horizonVisibleCount: 18,
                                        fadeVisibleCount: 7,
                                        fadeAnimatingCount: 3,
                                        cycleActive: true,
                                        cycleCursor: 256,
                                        cycleGroupCount: 1024,
                                        cycleComplete: false,
                                        labels: nil,
                                        hotBuckets: "4/2:8/3/2",
                                        maxHotBucketCount: 8,
                                        droppedEventCount: 0))
        recorder.stopRecording()

        let lines = try readJSONLines(fileURL)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0]["labelsIncluded"] as? Bool, false)
        XCTAssertNil(lines[0]["labels"])
        XCTAssertEqual(lines[0]["hotBuckets"] as? String, "4/2:8/3/2")
    }

    func testDefaultTraceOptionsSampleFullLabelsSparsely() {
        let options = BaseLabelTraceOptions.default

        XCTAssertFalse(options.shouldIncludeFullLabels(frameIndex: 41,
                                                       baseTrackedTilesChanged: true,
                                                       projectionChanged: true,
                                                       maxHotBucketCount: 8))
        XCTAssertTrue(options.shouldIncludeFullLabels(frameIndex: 60,
                                                      baseTrackedTilesChanged: false,
                                                      projectionChanged: false,
                                                      maxHotBucketCount: 8))
        XCTAssertTrue(options.shouldIncludeFullLabels(frameIndex: 41,
                                                      baseTrackedTilesChanged: false,
                                                      projectionChanged: false,
                                                      maxHotBucketCount: options.fullLabelHotBucketThreshold))
    }

    func testUsesBaseLabelTraceFileNamePrefix() throws {
        let recorder = BaseLabelTraceRecorder(directoryURL: temporaryDirectory,
                                              now: { Date(timeIntervalSince1970: 1_000) })

        let fileURL = try XCTUnwrap(recorder.startRecording())

        XCTAssertTrue(fileURL.lastPathComponent.hasPrefix("immersive-map-base-label-trace-"))
        XCTAssertTrue(fileURL.lastPathComponent.hasSuffix(".jsonl"))
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
