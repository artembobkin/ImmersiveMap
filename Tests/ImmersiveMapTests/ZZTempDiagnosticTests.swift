// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import CoreGraphics
import XCTest

/// Temporary diagnostic, not for commit.
final class ZZTempDiagnosticTests: XCTestCase {
    private func offlineSettings(_ settings: ImmersiveMapSettings = .default) -> ImmersiveMapSettings {
        var offline = settings
        offline.tileProvider = AnyImmersiveMapTileProvider(
            ImmersiveMapTilesProvider(tileBaseURL: URL(string: "http://127.0.0.1:1/tiles")!))
        return offline
    }

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
                throw XCTSkip("no context")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    private struct Diff {
        var count = 0
        var maxDelta = 0
        var insideGlobe = 0
        var outsideGlobe = 0
        var alphaDiffers = 0
    }

    private func diff(_ lhs: CGImage, _ rhs: CGImage) throws -> Diff {
        let a = try readPixels(from: lhs)
        let b = try readPixels(from: rhs)
        let width = lhs.width
        var result = Diff()
        for index in stride(from: 0, to: a.count, by: 4) {
            let pixel = index / 4
            let x = Double(pixel % width), y = Double(pixel / width)
            var differs = false
            for channel in 0..<4 {
                let delta = abs(Int(a[index + channel]) - Int(b[index + channel]))
                if delta > 0 {
                    differs = true
                    result.maxDelta = max(result.maxDelta, delta)
                    if channel == 3 { result.alphaDiffers += 1 }
                }
            }
            if differs {
                result.count += 1
                let centre = Double(width) / 2
                let radius = ((x - centre) * (x - centre) + (y - centre) * (y - centre)).squareRoot()
                // The globe at zoom 1 covers roughly the middle third.
                if radius < Double(width) * 0.28 { result.insideGlobe += 1 } else { result.outsideGlobe += 1 }
            }
        }
        return result
    }

    @MainActor
    func testWhatIsUnstable() async throws {
        try MetalTestEnvironment.requireDevice()
        let configuration = ImmersiveMapStillConfiguration(width: 128,
                                                           height: 128,
                                                           pixelsPerPoint: 1,
                                                           settleTimeout: 0,
                                                           sceneDate: Date(timeIntervalSinceReferenceDate: 0))
        let camera = ImmersiveMapCameraPosition(latitudeDegrees: 0, longitudeDegrees: 0, zoom: 1)

        var noStars = ImmersiveMapSettings.default.earthScene(isEnabled: false)
        noStars.scene.starfield.starCount = 0

        let cases: [(String, ImmersiveMapSettings)] = [
            ("as the failing test (earthScene off)", .default.earthScene(isEnabled: false)),
            ("transparent space", .default.earthScene(isEnabled: false).transparentSpace()),
            ("starCount = 0", noStars),
            ("stock default", .default),
        ]

        for (name, base) in cases {
            let settings = offlineSettings(base)
            let first = try await ImmersiveMapStillRecorder().capture(settings: settings,
                                                                      camera: camera,
                                                                      configuration: configuration)
            let second = try await ImmersiveMapStillRecorder().capture(settings: settings,
                                                                       camera: camera,
                                                                       configuration: configuration)
            let third = try await ImmersiveMapStillRecorder().capture(settings: settings,
                                                                      camera: camera,
                                                                      configuration: configuration)
            let d12 = try diff(first, second)
            let d23 = try diff(second, third)
            print("DIAG [\(name)] 1v2 count=\(d12.count) maxDelta=\(d12.maxDelta) "
                + "inGlobe=\(d12.insideGlobe) outGlobe=\(d12.outsideGlobe) alpha=\(d12.alphaDiffers) "
                + "| 2v3 count=\(d23.count) maxDelta=\(d23.maxDelta) "
                + "inGlobe=\(d23.insideGlobe) outGlobe=\(d23.outsideGlobe)")
        }
    }
}
