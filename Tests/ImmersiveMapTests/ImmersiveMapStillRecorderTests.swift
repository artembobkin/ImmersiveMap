// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import XCTest

/// The public still capture: geometry validation, and that a captured frame is
/// a real picture of the map with its alpha intact. The rendering cases need
/// the compiled Metal library, so they skip under `swift test` and run in the
/// xcodebuild workspace suite.
final class ImmersiveMapStillRecorderTests: XCTestCase {
    // MARK: - Configuration

    func testDefaultConfigurationValidates() throws {
        XCTAssertNoThrow(try ImmersiveMapStillConfiguration.default.validate())
    }

    func testValidationNamesTheFieldThatIsOutOfRange() {
        func reason(_ configuration: ImmersiveMapStillConfiguration) -> String? {
            do {
                try configuration.validate()
                return nil
            } catch let error as ImmersiveMapStillCaptureError {
                guard case let .invalidConfiguration(field) = error else {
                    return nil
                }
                return field
            } catch {
                return nil
            }
        }

        XCTAssertEqual(reason(ImmersiveMapStillConfiguration(width: 0))?.contains("width"), true)
        XCTAssertEqual(reason(ImmersiveMapStillConfiguration(height: 20_000))?.contains("height"), true)
        XCTAssertEqual(reason(ImmersiveMapStillConfiguration(pixelsPerPoint: 0))?.contains("pixelsPerPoint"), true)
        XCTAssertEqual(reason(ImmersiveMapStillConfiguration(tileReadinessTimeout: -1))?
            .contains("tileReadinessTimeout"), true)
    }

    /// Odd sizes are allowed, unlike video: there is no encoder demanding even
    /// dimensions, and a caller asking for a 375 point wide share image should
    /// get one.
    func testOddDimensionsAreAllowed() {
        XCTAssertNoThrow(try ImmersiveMapStillConfiguration(width: 375, height: 667).validate())
    }

    @MainActor
    func testCaptureRejectsAnInvalidConfigurationBeforeTouchingTheGPU() async {
        let recorder = ImmersiveMapStillRecorder()
        do {
            _ = try await recorder.capture(configuration: ImmersiveMapStillConfiguration(width: 0))
            XCTFail("A zero width must not be captured")
        } catch let error as ImmersiveMapStillCaptureError {
            guard case .invalidConfiguration = error else {
                return XCTFail("Expected an invalid configuration, got \(error)")
            }
        } catch {
            XCTFail("Expected ImmersiveMapStillCaptureError, got \(error)")
        }
        XCTAssertFalse(recorder.isCapturing, "A rejected capture must not leave the recorder busy")
    }

    /// One recorder captures one frame at a time. The second caller is told so
    /// rather than being handed a frame from an engine another capture is
    /// still driving.
    @MainActor
    func testASecondCaptureOnABusyRecorderIsRefused() async throws {
        try MetalTestEnvironment.requireDevice()
        let recorder = ImmersiveMapStillRecorder()
        let configuration = ImmersiveMapStillConfiguration(width: 64,
                                                           height: 64,
                                                           pixelsPerPoint: 1,
                                                           tileReadinessTimeout: 0,
                                                           sceneDate: Date(timeIntervalSinceReferenceDate: 0))

        // Both run on the main actor, so the second call gets its turn while
        // the first is suspended awaiting the GPU, which is exactly the window
        // the guard exists for.
        async let first: CGImage = recorder.capture(configuration: configuration)
        async let second: CGImage = recorder.capture(configuration: configuration)

        var failures: [ImmersiveMapStillCaptureError] = []
        do {
            _ = try await first
        } catch let error as ImmersiveMapStillCaptureError {
            failures.append(error)
        }
        do {
            _ = try await second
        } catch let error as ImmersiveMapStillCaptureError {
            failures.append(error)
        }

        XCTAssertEqual(failures, [.captureAlreadyInProgress],
                       "Exactly one of two overlapping captures must be refused")
        XCTAssertFalse(recorder.isCapturing, "The recorder must be free again afterwards")
    }

    // MARK: - Rendering

    /// The frame comes back at the requested size, with the map drawn on it
    /// and the space around it left unpainted.
    ///
    /// Transparent space is what makes this decidable without a reference
    /// image: the corners must carry no coverage at all and the middle of the
    /// globe must be fully covered, so a blank capture and a fully painted one
    /// both fail.
    @MainActor
    func testCaptureRendersTheMapAndKeepsItsAlpha() async throws {
        try MetalTestEnvironment.requireDevice()
        let recorder = ImmersiveMapStillRecorder()
        let configuration = ImmersiveMapStillConfiguration(width: 160,
                                                           height: 160,
                                                           pixelsPerPoint: 1,
                                                           tileReadinessTimeout: 0,
                                                           sceneDate: Date(timeIntervalSinceReferenceDate: 0))

        let image = try await recorder.capture(settings: offlineSettings(.default.transparentSpace()),
                                               camera: ImmersiveMapCameraPosition(latitudeDegrees: 0,
                                                                                  longitudeDegrees: 0,
                                                                                  zoom: 1),
                                               configuration: configuration)

        XCTAssertEqual(image.width, 160)
        XCTAssertEqual(image.height, 160)

        let pixels = try readPixels(from: image)
        XCTAssertEqual(alpha(in: pixels, x: 0, y: 0, width: 160), 0,
                       "Space around the globe must stay unpainted")
        XCTAssertEqual(alpha(in: pixels, x: 80, y: 80, width: 160), 255,
                       "The globe itself must be fully covered")
    }

    /// Proves the controllers passed to `capture` actually reach the renderer.
    /// Without them the argument would be silently ignored and every capture
    /// would look the same.
    @MainActor
    func testRoutesPassedToCaptureReachTheImage() async throws {
        try MetalTestEnvironment.requireDevice()
        let configuration = ImmersiveMapStillConfiguration(width: 128,
                                                           height: 128,
                                                           pixelsPerPoint: 1,
                                                           tileReadinessTimeout: 0,
                                                           sceneDate: Date(timeIntervalSinceReferenceDate: 0))
        let camera = ImmersiveMapCameraPosition(latitudeDegrees: 0, longitudeDegrees: 0, zoom: 1)
        let settings = offlineSettings(.default.earthScene(isEnabled: false))

        let withoutRoute = try await ImmersiveMapStillRecorder().capture(settings: settings,
                                                                         camera: camera,
                                                                         configuration: configuration)

        let route = ImmersiveMapRoute(id: 1,
                                      path: ImmersiveMapGeoPath(from: GeoCoordinate(latitude: 0, longitude: -20),
                                                                to: GeoCoordinate(latitude: 0, longitude: 20),
                                                                peakAltitudeMeters: 500_000),
                                      color: SIMD4<Float>(1, 0, 0, 1),
                                      widthPoints: 6,
                                      progress: 1)
        let withRoute = try await ImmersiveMapStillRecorder().capture(settings: settings,
                                                                      camera: camera,
                                                                      routes: [route],
                                                                      configuration: configuration)

        // Stated as a difference between two frames rather than as a count of
        // red pixels. With no tiles in either capture the map underneath is
        // identical, so anything that differs is the route, and the claim
        // survives whatever a given GPU and colour pipeline do to the exact
        // shade that comes back.
        XCTAssertGreaterThan(try differingPixelCount(withoutRoute, withRoute), 100,
                             "A route across the globe must reach the captured image")
    }

    /// Content passed to a capture is a value, so capturing twice draws it
    /// twice.
    ///
    /// The controllers a renderer consumes hand over their state as a one-shot
    /// diff. An earlier version of this API took the controllers themselves,
    /// which meant the first capture drained the diff and every capture after
    /// it drew an empty map, and sharing a controller with a live map took the
    /// state that map had not read yet.
    @MainActor
    func testTheSameContentCanBeCapturedTwice() async throws {
        try MetalTestEnvironment.requireDevice()
        let configuration = ImmersiveMapStillConfiguration(width: 128,
                                                           height: 128,
                                                           pixelsPerPoint: 1,
                                                           tileReadinessTimeout: 0,
                                                           sceneDate: Date(timeIntervalSinceReferenceDate: 0))
        let camera = ImmersiveMapCameraPosition(latitudeDegrees: 0, longitudeDegrees: 0, zoom: 1)
        let settings = offlineSettings(.default.earthScene(isEnabled: false))
        let routes = [ImmersiveMapRoute(id: 1,
                                        path: ImmersiveMapGeoPath(from: GeoCoordinate(latitude: 0, longitude: -20),
                                                                  to: GeoCoordinate(latitude: 0, longitude: 20),
                                                                  peakAltitudeMeters: 500_000),
                                        color: SIMD4<Float>(1, 0, 0, 1),
                                        widthPoints: 6,
                                        progress: 1)]

        let recorder = ImmersiveMapStillRecorder()
        let baseline = try await recorder.capture(settings: settings,
                                                  camera: camera,
                                                  configuration: configuration)
        let first = try await recorder.capture(settings: settings,
                                               camera: camera,
                                               routes: routes,
                                               configuration: configuration)
        let second = try await recorder.capture(settings: settings,
                                                camera: camera,
                                                routes: routes,
                                                configuration: configuration)

        XCTAssertGreaterThan(try differingPixelCount(baseline, first), 100)
        XCTAssertGreaterThan(try differingPixelCount(baseline, second), 100,
                             "The second capture of the same content must still draw it")
    }

    // MARK: - Helpers

    /// Settings whose tile provider points at a port nothing listens on.
    ///
    /// A test that renders the real provider depends on a tile service, a CDN
    /// and how warm the local disk cache happens to be, which is three ways
    /// for the same assertion to mean something different on a laptop and on
    /// a runner. Nothing here is about tiles.
    private func offlineSettings(_ settings: ImmersiveMapSettings = .default) -> ImmersiveMapSettings {
        var offline = settings
        offline.tileProvider = AnyImmersiveMapTileProvider(
            ImmersiveMapTilesProvider(tileBaseURL: URL(string: "http://127.0.0.1:1/tiles")!))
        return offline
    }

    /// Redraws the image into a known layout, so the assertions do not depend
    /// on the byte order the capture happened to use.
    private func readPixels(from image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress,
                                          width: image.width,
                                          height: image.height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw XCTSkip("Could not create a readback context")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    private func alpha(in pixels: [UInt8], x: Int, y: Int, width: Int) -> UInt8 {
        pixels[(y * width + x) * 4 + 3]
    }

    /// How many pixels differ between two captures of the same size.
    private func differingPixelCount(_ lhs: CGImage, _ rhs: CGImage) throws -> Int {
        let left = try readPixels(from: lhs)
        let right = try readPixels(from: rhs)
        var differing = 0
        for index in stride(from: 0, to: min(left.count, right.count), by: 4) {
            let sameRed = left[index] == right[index]
            let sameGreen = left[index + 1] == right[index + 1]
            let sameBlue = left[index + 2] == right[index + 2]
            let sameAlpha = left[index + 3] == right[index + 3]
            if sameRed && sameGreen && sameBlue && sameAlpha {
                continue
            }
            differing += 1
        }
        return differing
    }
}
