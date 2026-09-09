// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// `.globe(isEnabled: false)` end to end: at a zoom where the default map is
/// a sphere with space around it, the globe-disabled map is the plane, which
/// at this zoom fills the frame, so no pixel is space and every pixel is the
/// map's clear colour of a tileless plane. Requires the compiled Metal
/// library, so it skips under `swift test` and runs in the xcodebuild
/// workspace suite.
final class GlobeDisabledOffscreenRenderTests: XCTestCase {
    @MainActor
    func testTheGlobeDisabledMapIsThePlaneAtLowZoom() async throws {
        var settings = ImmersiveMapSettings.default
        settings.scene.starfield.starCount = 0
        let space = Self.pixel(of: settings.scene.space.clearColor)
        let map = Self.pixel(of: settings.scene.mapClearColor)

        let globe = try await renderFrame(settings: settings)
        XCTAssertTrue(globe.corners.allSatisfy { Self.distance($0, space) <= 2 },
                      "The default map at zoom 1 is a sphere with space in the corners")

        let plane = try await renderFrame(settings: settings.globe(isEnabled: false))
        XCTAssertEqual(plane.count(where: { Self.distance($0, map) > 2 }), 0,
                       "With the globe off the plane covers the frame in the map's clear colour")
    }

    @MainActor
    private func renderFrame(settings: ImmersiveMapSettings) async throws -> RenderedFrame {
        let harness = try OffscreenFrameHarness.makeOrSkip(settings: settings)
        harness.setZoom(1.0)
        return try await harness.renderFrame()
    }

    private static func pixel(of color: SIMD4<Double>) -> RenderedFrame.Pixel {
        RenderedFrame.Pixel(red: UInt8((color.x * 255).rounded()),
                            green: UInt8((color.y * 255).rounded()),
                            blue: UInt8((color.z * 255).rounded()),
                            alpha: 255)
    }

    private static func distance(_ a: RenderedFrame.Pixel, _ b: RenderedFrame.Pixel) -> Int {
        max(abs(Int(a.red) - Int(b.red)), abs(Int(a.green) - Int(b.green)), abs(Int(a.blue) - Int(b.blue)))
    }
}
