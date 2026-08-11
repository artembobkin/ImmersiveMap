// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// End-to-end shadow check: a tall obelisk model must darken a wide flat slab
/// placed north-east of it (the default light shines from the south-west), and
/// toggling `ShadowSettings.isEnabled` live must brighten/darken the frame.
/// Requires the compiled Metal library, so it skips under `swift test` and
/// runs in the xcodebuild workspace suite.
final class ShadowOffscreenRenderTests: XCTestCase {
    @MainActor
    func testShadowToggleChangesSlabBrightness() async throws {
        let settings = ImmersiveMapSettings.default
        let harness = try OffscreenFrameHarness.makeOrSkip(settings: settings, size: 128)

        // Zoom 16 keeps the flat presentation on (transition saturates at
        // zoom 7) and the resolver's 1000 m caster-height cap comfortably
        // above the 800 m obelisk.
        harness.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: 0,
                                                             longitudeDegrees: 0,
                                                             zoom: 16))

        let baseline = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(0))

        // Caster: an 800 m obelisk with an 80 m footprint at the camera
        // center. Its shadow reaches ~(320 m E, 480 m N) at the tip.
        let obeliskURL = try writeObeliskOBJ()
        defer { try? FileManager.default.removeItem(at: obeliskURL) }
        harness.sceneModels.add(ImmersiveMapSceneModel(
            id: 1,
            source: ImmersiveMapSceneModel.Source(url: obeliskURL),
            coordinate: GeoCoordinate(latitude: 0, longitude: 0),
            fitDiameterMeters: 800))

        // Receiver: a 400x400 m slab, 4 m thick, centered mid-shadow to the
        // north-east (1 degree ~= 111.32 km at the equator).
        let slabURL = try writeSlabOBJ()
        defer { try? FileManager.default.removeItem(at: slabURL) }
        harness.sceneModels.add(ImmersiveMapSceneModel(
            id: 2,
            source: ImmersiveMapSceneModel.Source(url: slabURL),
            coordinate: GeoCoordinate(latitude: 240.0 / 111_320.0,
                                      longitude: 160.0 / 111_320.0),
            fitDiameterMeters: 400))

        // Meshes load asynchronously off-main, so the frame that added them
        // does not contain them yet: render on until both models have settled.
        let shadowsOn = try await harness.renderUntilSettled(changedFrom: baseline,
                                                             startingAt: OffscreenFrameHarness.frameTime(1))
        let shadowsOnSum = shadowsOn.brightnessSum

        // The follow-up frames continue from wherever the wait ended rather
        // than at a named time: the scripted clock is monotonic, and a literal
        // chosen to clear today's settling budget would move time backwards
        // the day that budget grows.
        harness.engine.applySettings(settings.shadows(isEnabled: false))
        let shadowsOffSum = try await harness.renderNextFrame().brightnessSum

        XCTAssertGreaterThan(shadowsOffSum, shadowsOnSum,
                             "Disabling shadows must brighten the slab north-east of the obelisk")

        harness.engine.applySettings(settings.shadows(isEnabled: true))
        let shadowsBackSum = try await harness.renderNextFrame().brightnessSum
        XCTAssertLessThan(shadowsBackSum, shadowsOffSum,
                          "Re-enabling shadows must darken the frame again")
    }

    /// A tall thin column: 0.2x0.2 footprint, height 2 (the fit dimension).
    private func writeObeliskOBJ() throws -> URL {
        try writeOBJ(name: "shadow-obelisk", halfX: 0.1, height: 2.0, halfZ: 0.1)
    }

    /// A wide flat slab: 20x20 footprint (the fit dimension), height 0.2.
    private func writeSlabOBJ() throws -> URL {
        try writeOBJ(name: "shadow-slab", halfX: 10.0, height: 0.2, halfZ: 10.0)
    }

    private func writeOBJ(name: String, halfX: Double, height: Double, halfZ: Double) throws -> URL {
        let obj = """
        v -\(halfX) 0 -\(halfZ)
        v \(halfX) 0 -\(halfZ)
        v \(halfX) \(height) -\(halfZ)
        v -\(halfX) \(height) -\(halfZ)
        v -\(halfX) 0 \(halfZ)
        v \(halfX) 0 \(halfZ)
        v \(halfX) \(height) \(halfZ)
        v -\(halfX) \(height) \(halfZ)
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
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
            .appendingPathExtension("obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
