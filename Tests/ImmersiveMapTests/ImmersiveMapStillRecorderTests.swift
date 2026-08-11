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

        let image = try await recorder.capture(settings: .default.transparentSpace(),
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
        let settings = ImmersiveMapSettings.default.earthScene(isEnabled: false)

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

        // Counted by colour rather than by diffing the two frames: tiles keep
        // arriving between captures, so a byte difference would prove only
        // that the map moved on, not that the route was drawn.
        XCTAssertEqual(try routePixelCount(in: withoutRoute), 0,
                       "The map has no red of its own")
        XCTAssertGreaterThan(try routePixelCount(in: withRoute), 0,
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
        let settings = ImmersiveMapSettings.default.earthScene(isEnabled: false)
        let routes = [ImmersiveMapRoute(id: 1,
                                        path: ImmersiveMapGeoPath(from: GeoCoordinate(latitude: 0, longitude: -20),
                                                                  to: GeoCoordinate(latitude: 0, longitude: 20),
                                                                  peakAltitudeMeters: 500_000),
                                        color: SIMD4<Float>(1, 0, 0, 1),
                                        widthPoints: 6,
                                        progress: 1)]

        let recorder = ImmersiveMapStillRecorder()
        let first = try await recorder.capture(settings: settings,
                                               camera: camera,
                                               routes: routes,
                                               configuration: configuration)
        let second = try await recorder.capture(settings: settings,
                                                camera: camera,
                                                routes: routes,
                                                configuration: configuration)

        // Stated as "the route is in both frames" rather than "the frames are
        // identical": tiles the first capture fetched are on disk for the
        // second, so the map underneath is allowed to differ. The route is
        // what this test is about.
        XCTAssertGreaterThan(try routePixelCount(in: first), 0)
        XCTAssertGreaterThan(try routePixelCount(in: second), 0,
                             "The second capture of the same content must still draw it")
    }

    // MARK: - Helpers

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

    /// The map has no red anywhere in its default palette, so a saturated red
    /// pixel can only have come from the red route these tests add.
    private func routePixelCount(in image: CGImage) throws -> Int {
        let pixels = try readPixels(from: image)
        return stride(from: 0, to: pixels.count, by: 4).count { index in
            pixels[index] > 150 && pixels[index + 1] < 90 && pixels[index + 2] < 90
        }
    }
}
