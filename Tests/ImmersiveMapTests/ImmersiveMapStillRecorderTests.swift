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
        XCTAssertEqual(reason(ImmersiveMapStillConfiguration(settleTimeout: -1))?
            .contains("settleTimeout"), true)
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
            _ = try await recorder.capture(settings: FixtureTiles.tilelessSettings(),
                                           configuration: ImmersiveMapStillConfiguration(width: 0))
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
                                                           settleTimeout: 0,
                                                           sceneDate: Date(timeIntervalSinceReferenceDate: 0))

        // Settings spelled out rather than left to the default argument: the
        // capture that gets through builds a whole runtime, and `capture`
        // defaults to `ImmersiveMapSettings.default`, which streams from the
        // hosted tile service.
        let settings = FixtureTiles.tilelessSettings()

        // Both run on the main actor, so the second call gets its turn while
        // the first is suspended awaiting the GPU, which is exactly the window
        // the guard exists for.
        async let first: CGImage = recorder.capture(settings: settings, configuration: configuration)
        async let second: CGImage = recorder.capture(settings: settings, configuration: configuration)

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

    /// The frame comes back at the requested size, with the globe drawn on it
    /// and the space around it left unpainted.
    ///
    /// The globe, not the map: this renders tile-free, so what covers the
    /// middle is the globe surface itself. What a tile adds to a capture is
    /// asserted by `testSceneModelsReachTheCapturedImage`, which serves them
    /// from the fixture service.
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
                                                           settleTimeout: 0,
                                                           sceneDate: Date(timeIntervalSinceReferenceDate: 0))

        let image = try await recorder.capture(settings: FixtureTiles.tilelessSettings(.default.transparentSpace()),
                                               camera: ImmersiveMapCameraPosition(latitudeDegrees: 0,
                                                                                  longitudeDegrees: 0,
                                                                                  zoom: 1),
                                               configuration: configuration)

        XCTAssertEqual(image.width, 160)
        XCTAssertEqual(image.height, 160)

        let pixels = try readPixels(from: image)
        XCTAssertEqual(alpha(in: pixels, x: 0, y: 0, width: 160), 0,
                       "Space around the globe must stay unpainted")
        // With the placeholder grid gone, a tileless globe paints nothing:
        // the disc is transparent until tiles arrive.
        XCTAssertEqual(alpha(in: pixels, x: 80, y: 80, width: 160), 0,
                       "A tileless globe carries no surface to cover the disc")
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
                                                           settleTimeout: 0,
                                                           sceneDate: Date(timeIntervalSinceReferenceDate: 0))
        let camera = ImmersiveMapCameraPosition(latitudeDegrees: 0, longitudeDegrees: 0, zoom: 1)
        // Tile-free, not merely provider-less: the noise-floor assertion below
        // requires two captures of the same scene to be identical, and a tile
        // arriving in one of them but not the other breaks that by thousands
        // of pixels.
        let settings = FixtureTiles.tilelessSettings(.default)

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
        // The noise floor, measured rather than assumed: two captures of the
        // same scene. It has to be zero for the comparison below to mean
        // anything, and an earlier version of this test failed on CI for
        // exactly that reason. Space is transparent here because the starfield
        // twinkles with scene time, and the settle loop does not always take
        // the same number of passes, so with stars on screen two captures
        // differ by thousands of pixels that have nothing to do with routes.
        let secondBaseline = try await ImmersiveMapStillRecorder().capture(settings: settings,
                                                                            camera: camera,
                                                                            configuration: configuration)
        XCTAssertEqual(try differingPixelCount(withoutRoute, secondBaseline), 0,
                       "Two captures of the same scene must be identical, or the comparison below is noise")
        XCTAssertGreaterThan(try differingPixelCount(withoutRoute, withRoute), 20,
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
                                                           settleTimeout: 0,
                                                           sceneDate: Date(timeIntervalSinceReferenceDate: 0))
        let camera = ImmersiveMapCameraPosition(latitudeDegrees: 0, longitudeDegrees: 0, zoom: 1)
        // Space left opaque on purpose: the starfield is the part of the map
        // most sensitive to where the clock stopped, so if captures are
        // reproducible with stars on screen they are reproducible.
        let settings = FixtureTiles.tilelessSettings(.default)
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

        XCTAssertGreaterThan(try differingPixelCount(baseline, first), 20)
        XCTAssertGreaterThan(try differingPixelCount(baseline, second), 20,
                             "The second capture of the same content must still draw it")
    }

    // MARK: - Helpers

    /// A scene model handed to a capture is in the frame it returns.
    ///
    /// A smoke test, not a proof: it cannot fail the race it is about. A mesh
    /// this small loads inside the settle floor whether or not the loop waits
    /// for it, which was verified by removing the wait and watching this still
    /// pass. What the capture actually waits on is asserted where it is
    /// decidable, in `SceneModelPendingMeshDiagnosticsTests`.
    @MainActor
    func testSceneModelsReachTheCapturedImage() async throws {
        try MetalTestEnvironment.requireDevice()
        let configuration = ImmersiveMapStillConfiguration(width: 128,
                                                           height: 128,
                                                           pixelsPerPoint: 1,
                                                           settleTimeout: 10,
                                                           sceneDate: Date(timeIntervalSinceReferenceDate: 0))
        let camera = ImmersiveMapCameraPosition(latitudeDegrees: 0, longitudeDegrees: 0, zoom: 16)
        // A model needs a map under it: with no tiles at all the flat frame
        // has no tile origin and nothing in the world pass is drawn, model
        // included (measured: the two captures came back identical). The
        // tiles come from the in-process fixture service rather than the live
        // tile service, so the case does not depend on the network, on rate
        // limiting, or on tiles arriving inside the settle window.
        let settings = FixtureTiles.settings()

        let withoutModel = try await ImmersiveMapStillRecorder().capture(settings: settings,
                                                                         camera: camera,
                                                                         configuration: configuration)

        let objURL = try writeCubeOBJ()
        defer { try? FileManager.default.removeItem(at: objURL) }
        let model = ImmersiveMapSceneModel(id: 1,
                                           source: ImmersiveMapSceneModel.Source(url: objURL),
                                           coordinate: GeoCoordinate(latitude: 0, longitude: 0),
                                           fitDiameterMeters: 400)
        let withModel = try await ImmersiveMapStillRecorder().capture(settings: settings,
                                                                      camera: camera,
                                                                      sceneModels: [model],
                                                                      configuration: configuration)

        // No polling here on purpose: the capture is supposed to have done the
        // waiting. A single comparison is what proves it did.
        XCTAssertGreaterThan(try differingPixelCount(withoutModel, withModel), 100,
                             "The scene model must be in the frame the capture returned")
    }

    private func writeCubeOBJ() throws -> URL {
        let obj = """
        v -1 0 -1
        v 1 0 -1
        v 1 2 -1
        v -1 2 -1
        v -1 0 1
        v 1 0 1
        v 1 2 1
        v -1 2 1
        f 1 3 2
        f 1 4 3
        f 5 6 7
        f 5 7 8
        f 1 2 6
        f 1 6 5
        f 2 3 7
        f 2 7 6
        f 3 4 8
        f 3 8 7
        f 4 1 5
        f 4 5 8
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("still-scene-model-\(UUID().uuidString)")
            .appendingPathExtension("obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        return url
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

    /// How many pixels differ visibly between two captures of the same size.
    ///
    /// Visibly, not exactly: rasterization is not bit-reproducible on every
    /// GPU, and comparing byte for byte counted about half the frame as
    /// changed on a CI runner for two captures of the same scene. The
    /// tolerance is far below anything a person could see and far above that
    /// noise, so what it counts is content, not rounding.
    private func differingPixelCount(_ lhs: CGImage,
                                     _ rhs: CGImage,
                                     tolerance: UInt8 = 12) throws -> Int {
        let left = try readPixels(from: lhs)
        let right = try readPixels(from: rhs)
        var differing = 0
        for index in stride(from: 0, to: min(left.count, right.count), by: 4) {
            var isDifferent = false
            for channel in 0..<4 where isDifferent == false {
                let a = left[index + channel]
                let b = right[index + channel]
                isDifferent = (a > b ? a - b : b - a) > tolerance
            }
            if isDifferent {
                differing += 1
            }
        }
        return differing
    }
}
