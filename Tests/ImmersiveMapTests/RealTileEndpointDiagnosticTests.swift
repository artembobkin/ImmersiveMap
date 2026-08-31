// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImmersiveMap
import XCTest

/// A manual diagnostic, not part of the suite: renders the live tile
/// endpoint offscreen so a rendering regression that only real content can
/// show (fixture tiles are simpler than the planet) is caught by a machine
/// instead of by someone staring at an app. Every case skips unless
/// `IMMERSIVEMAP_REAL_TILES_DIAG=1` is in the environment (for xcodebuild,
/// prefix it as `TEST_RUNNER_IMMERSIVEMAP_REAL_TILES_DIAG=1`), so the
/// suite's rule that tests never fetch tiles from the network stands: on CI
/// and in a plain run these cases do nothing. A compiled Metal library is
/// also required, so the run goes through xcodebuild, not `swift test`:
///
///     TEST_RUNNER_IMMERSIVEMAP_REAL_TILES_DIAG=1 xcodebuild test \
///       -workspace .swiftpm/xcode/package.xcworkspace \
///       -scheme ImmersiveMap -destination 'platform=macOS' \
///       -only-testing:ImmersiveMapTests/RealTileEndpointDiagnosticTests
///
/// (the prefix must be in xcodebuild's environment, the way ci.yml passes
/// IMMERSIVE_MAP_REQUIRE_METAL; a trailing NAME=VALUE build setting does
/// not reach the runner)
///
/// Each case captures one frame through `ImmersiveMapStillRecorder`, writes
/// the PNG next to the system temporary directory for a human look, and
/// asserts the centre of the picture is chromatic: the placeholder fill and
/// space are near-achromatic, real ocean and landcover are not.
final class RealTileEndpointDiagnosticTests: XCTestCase {
    /// The whole planet on the pure sphere.
    @MainActor
    func testRealTilesPaintTheGlobeDisc() async throws {
        try await assertChromaticCentre(zoom: 1.6, imageName: "real-tiles-globe")
    }

    /// The middle of the unfurl, where the morph vertex path draws.
    @MainActor
    func testRealTilesPaintTheMidMorphSurface() async throws {
        try await assertChromaticCentre(zoom: 6.6, imageName: "real-tiles-morph")
    }

    @MainActor
    private func assertChromaticCentre(zoom: Double, imageName: String) async throws {
        guard ProcessInfo.processInfo.environment["IMMERSIVEMAP_REAL_TILES_DIAG"] == "1" else {
            throw XCTSkip("Opt-in diagnostic: set IMMERSIVEMAP_REAL_TILES_DIAG=1 to run against the live endpoint")
        }
        if let reason = MetalTestEnvironment.unavailabilityReason() {
            throw XCTSkip(reason)
        }
        guard let key = Self.localAPIKey(), key.isEmpty == false else {
            throw XCTSkip("No IMMERSIVEMAP_API_KEY in LocalSecrets.plist")
        }
        // Deliberately the live endpoint: reaching it is this diagnostic's
        // whole purpose, behind the opt-in gate above. The base is the
        // tileless fixture settings, so the shipped defaults are never
        // rebuilt by accident and both disk caches stay off (every run
        // fetches fresh tiles).
        let settings = FixtureTiles.tilelessSettings()
            .tileURLTemplate("https://immersivemap.dev/tiles/{z}/{x}/{y}.mvt",
                             headers: ["Authorization": "Bearer \(key)"])
        let recorder = ImmersiveMapStillRecorder()
        let camera = ImmersiveMapCameraPosition(latitudeDegrees: 55.75, longitudeDegrees: 37.61, zoom: zoom)
        var configuration = ImmersiveMapStillConfiguration(width: 900, height: 900, pixelsPerPoint: 1)
        configuration.settleTimeout = 40
        let image = try await recorder.capture(settings: settings, camera: camera, configuration: configuration)

        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var chromatic = 0
        var total = 0
        for y in stride(from: height / 2 - 150, to: height / 2 + 150, by: 2) {
            for x in stride(from: width / 2 - 150, to: width / 2 + 150, by: 2) {
                let i = (y * width + x) * 4
                let r = Int(pixels[i])
                let g = Int(pixels[i + 1])
                let b = Int(pixels[i + 2])
                total += 1
                if max(r, g, b) - min(r, g, b) > 25 { chromatic += 1 }
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(imageName).png")
        if let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        let share = Double(chromatic) / Double(max(total, 1))
        XCTAssertGreaterThan(share, 0.05,
                             "Centre is \(Int(share * 100))% chromatic (frame at \(url.path)); real ground should paint it")
    }

    private static func localAPIKey(named name: String = "IMMERSIVEMAP_API_KEY") -> String? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
                let secrets = directory.appendingPathComponent("LocalSecrets.plist")
                return NSDictionary(contentsOf: secrets)?[name] as? String
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }
}
