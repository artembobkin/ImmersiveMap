// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import AVFoundation
import Metal
import SwiftUI
import XCTest

/// Full-pipeline export smoke test: recorder → headless engine → tile gate →
/// pixel-buffer render → AVAssetWriter. Requires the compiled Metal library,
/// so it skips under `swift test` and runs in the xcodebuild workspace suite.
/// Tiles come from the in-process fixture service, so the tile gate is
/// exercised against bytes that are always there and never against a CDN.
final class TourVideoExportEndToEndTests: XCTestCase {
    private final class Owner {}

    @MainActor
    func testExportsTinyTourToPlayableMovie() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        guard (try? device.makeDefaultLibrary(bundle: .module)) != nil else {
            throw XCTSkip("Compiled Metal library is unavailable in this test environment")
        }

        let recorder = ImmersiveMapTourVideoRecorder()
        let owner = Owner()
        recorder.attachRuntime(owner: owner,
                               context: ImmersiveMapVideoExportAttachContext(
                                   currentSettings: { FixtureTiles.settings() },
                                   currentCameraPosition: { nil },
                                   currentAvatarsController: { nil },
                                   currentMarkerContent: { nil }))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("immersive-map-e2e-export-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        let establish = ImmersiveMapCameraPosition(latitudeDegrees: 55.75,
                                                   longitudeDegrees: 37.61,
                                                   zoom: 2.0,
                                                   bearing: 0,
                                                   pitch: 0)
        let shot = ImmersiveMapCameraTourShot(position: ImmersiveMapCameraPosition(latitudeDegrees: 35.68,
                                                                                   longitudeDegrees: 139.76,
                                                                                   zoom: 2.5,
                                                                                   bearing: 0,
                                                                                   pitch: 0.2),
                                              options: CameraFlightOptions(duration: 0.2,
                                                                           routeStyle: .automatic,
                                                                           altitudeStyle: .direct),
                                              holdAfter: 0.05)
        let configuration = ImmersiveMapVideoExportConfiguration(width: 128,
                                                                 height: 128,
                                                                 framesPerSecond: 30,
                                                                 codec: .hevc,
                                                                 tileReadinessTimeout: 1)

        var lastProgress: ImmersiveMapVideoExportProgress?
        recorder.onProgress = { lastProgress = $0 }

        try await recorder.export(shots: [shot],
                                  establish: establish,
                                  configuration: configuration,
                                  to: url)

        XCTAssertFalse(recorder.isExporting)
        // totalDuration 0.25 s at 30 fps → ceil(7.5) + 1 = 9 frames → 0.3 s.
        XCTAssertEqual(lastProgress?.phase, .finishing)
        XCTAssertEqual(lastProgress?.framesCompleted, 9)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let summary = try await ExportedVideoProbe.summary(url: url)
        XCTAssertEqual(summary.durationSeconds, 9.0 / 30.0, accuracy: 1.0 / 30.0)
        XCTAssertEqual(summary.videoTrackCount, 1)
        XCTAssertEqual(summary.naturalSize, CGSize(width: 128, height: 128))
        XCTAssertEqual(summary.codec, kCMVideoCodecType_HEVC)
    }

    /// Exports the same single-frame scene twice (once with an avatar and a
    /// SwiftUI marker included, once with both excluded) and asserts the
    /// decoded frames differ, proving the overlays actually reach the video.
    @MainActor
    func testMarkersAndAvatarsAppearInExportedFrames() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device is unavailable")
        }
        guard (try? device.makeDefaultLibrary(bundle: .module)) != nil else {
            throw XCTSkip("Compiled Metal library is unavailable in this test environment")
        }

        let coordinate = GeoCoordinate(latitude: 48.85, longitude: 2.35)
        let establish = ImmersiveMapCameraPosition(latitudeDegrees: coordinate.latitude,
                                                   longitudeDegrees: coordinate.longitude,
                                                   zoom: 2.0,
                                                   bearing: 0,
                                                   pitch: 0)
        // A degenerate shot: zero flight, zero hold → exactly one frame.
        let shot = ImmersiveMapCameraTourShot(position: establish,
                                              options: CameraFlightOptions(duration: 0,
                                                                           routeStyle: .automatic,
                                                                           altitudeStyle: .direct))

        let avatarsController = ImmersiveMapAvatarsController()
        avatarsController.add(AvatarMarker(id: 1, coordinate: coordinate, image: makeSolidImage()))
        // The live engine has already drained the diff: the regression this
        // feature fixes.
        _ = avatarsController.consumeSnapshot()

        let markerContent = MarkerViewContent(anchor: .center,
                                              items: [MarkerViewItem(id: AnyHashable(1),
                                                                     coordinate: coordinate,
                                                                     content: AnyView(Color.red.frame(width: 40,
                                                                                                      height: 40)))])

        func exportFrame(includesOverlays: Bool) async throws -> [UInt8] {
            let recorder = ImmersiveMapTourVideoRecorder()
            recorder.attachRuntime(owner: self,
                                   context: ImmersiveMapVideoExportAttachContext(
                                       // Tile-free, not merely offline: this
                                       // case compares two exports of the
                                       // same scene, and a tile that made it
                                       // into one of them but not the other
                                       // would read as an overlay.
                                       currentSettings: { FixtureTiles.tilelessSettings() },
                                       currentCameraPosition: { nil },
                                       currentAvatarsController: { avatarsController },
                                       currentMarkerContent: { markerContent }))
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("immersive-map-overlay-export-\(UUID().uuidString).mov")
            defer { try? FileManager.default.removeItem(at: url) }
            let configuration = ImmersiveMapVideoExportConfiguration(width: 128,
                                                                     height: 128,
                                                                     framesPerSecond: 30,
                                                                     codec: .hevc,
                                                                     tileReadinessTimeout: 1,
                                                                     includesAvatars: includesOverlays,
                                                                     includesMarkers: includesOverlays)
            try await recorder.export(shots: [shot],
                                      establish: establish,
                                      configuration: configuration,
                                      to: url)
            return try await decodeFirstFramePixels(url: url)
        }

        let withOverlays = try await exportFrame(includesOverlays: true)
        let withoutOverlays = try await exportFrame(includesOverlays: false)

        let differingBytes = zip(withOverlays, withoutOverlays).count { $0 != $1 }
        XCTAssertGreaterThan(differingBytes, 1_000,
                             "The avatar and the marker must visibly change the exported frame")
    }

    private func makeSolidImage() -> CGImage {
        let context = CGContext(data: nil,
                                width: 64,
                                height: 64,
                                bitsPerComponent: 8,
                                bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return context.makeImage()!
    }

    @MainActor
    private func decodeFirstFramePixels(url: URL) async throws -> [UInt8] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let image = try await generator.image(at: .zero).image

        var pixels = [UInt8](repeating: 0, count: 128 * 128 * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress,
                                    width: 128,
                                    height: 128,
                                    bitsPerComponent: 8,
                                    bytesPerRow: 128 * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 128, height: 128))
        }
        return pixels
    }
}
