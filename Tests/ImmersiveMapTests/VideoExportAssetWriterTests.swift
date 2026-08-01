// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import AVFoundation
import XCTest

/// AVAssetWriter runs headless (no Metal, no GPU frame source needed): the
/// writer is exercised end-to-end with solid-color pixel buffers.
@MainActor
final class VideoExportAssetWriterTests: XCTestCase {
    private func makeTemporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("immersive-map-export-test-\(UUID().uuidString).mov")
    }

    private func fill(_ pixelBuffer: CVPixelBuffer, byte: UInt8) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let byteCount = CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer)
            memset(baseAddress, Int32(byte), byteCount)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    }

    func testWritesFourFrameMovie() async throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let configuration = ImmersiveMapVideoExportConfiguration(width: 64,
                                                                 height: 64,
                                                                 framesPerSecond: 60,
                                                                 codec: .h264)
        let writer = try VideoExportAssetWriter(url: url, configuration: configuration)
        try writer.start()

        for frameIndex in 0..<4 {
            let pixelBuffer = try await writer.makePixelBuffer()
            fill(pixelBuffer, byte: UInt8(40 + frameIndex * 50))
            try await writer.append(pixelBuffer, frameIndex: frameIndex)
        }
        try await writer.finish()

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 4.0 / 60.0, accuracy: 0.5 / 60.0)

        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let naturalSize = try await tracks[0].load(.naturalSize)
        XCTAssertEqual(naturalSize, CGSize(width: 64, height: 64))

        let formatDescriptions = try await tracks[0].load(.formatDescriptions)
        XCTAssertEqual(formatDescriptions.count, 1)
        let codecType = CMFormatDescriptionGetMediaSubType(formatDescriptions[0])
        XCTAssertEqual(codecType, kCMVideoCodecType_H264)
        let colorPrimaries = CMFormatDescriptionGetExtension(
            formatDescriptions[0],
            extensionKey: kCMFormatDescriptionExtension_ColorPrimaries
        ) as? String
        XCTAssertEqual(colorPrimaries, kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String)
    }

    func testWriterReplacesExistingFile() async throws {
        let url = makeTemporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("stale".utf8).write(to: url)

        let configuration = ImmersiveMapVideoExportConfiguration(width: 64,
                                                                 height: 64,
                                                                 framesPerSecond: 30,
                                                                 codec: .h264)
        let writer = try VideoExportAssetWriter(url: url, configuration: configuration)
        try writer.start()
        let pixelBuffer = try await writer.makePixelBuffer()
        fill(pixelBuffer, byte: 128)
        try await writer.append(pixelBuffer, frameIndex: 0)
        try await writer.finish()

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
    }

    func testCancelDeletesPartialFile() async throws {
        let url = makeTemporaryURL()
        let configuration = ImmersiveMapVideoExportConfiguration(width: 64,
                                                                 height: 64,
                                                                 framesPerSecond: 60,
                                                                 codec: .h264)
        let writer = try VideoExportAssetWriter(url: url, configuration: configuration)
        try writer.start()
        let pixelBuffer = try await writer.makePixelBuffer()
        fill(pixelBuffer, byte: 200)
        try await writer.append(pixelBuffer, frameIndex: 0)

        writer.cancel()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
