// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The globe wears the theme's globe palette and the plane the theme's
/// own: a night whose planet keeps its daylight. The ground is a fixture
/// ocean, the night's water a navy the plane shows and the globe's water
/// a magenta no other colour of the frame comes near.
final class GlobeNightOffscreenRenderTests: XCTestCase {
    private static let globeWater = SIMD4<Float>(1, 0, 1, 1)
    private static let planeWater = SIMD4<Float>(0.05, 0.1, 0.3, 1)

    /// On the resting globe the ocean is the globe palette's water.
    @MainActor
    func testTheGlobeWearsTheGlobePalette() async throws {
        let harness = try makeHarness(globe: true)
        let painted = try await paintedFrame(harness)

        let (magenta, checked) = Self.count(painted, where: Self.isGlobeWater)
        XCTAssertGreaterThan(checked, 100)
        XCTAssertGreaterThan(magenta, checked * 9 / 10,
                             "\(checked - magenta) of \(checked) pixels at the globe's centre are not the globe palette's water")
    }

    /// On the plane the same tiles show the theme's own water: the globe
    /// palette is the sphere's alone.
    @MainActor
    func testThePlaneWearsTheThemesOwnPalette() async throws {
        let harness = try makeHarness(globe: false)
        let painted = try await paintedFrame(harness)

        let (magenta, checked) = Self.count(painted, where: Self.isGlobeWater)
        let (navy, _) = Self.count(painted, where: Self.isPlaneWater)
        XCTAssertGreaterThan(checked, 100)
        XCTAssertEqual(magenta, 0, "The globe palette's water shows on the plane")
        XCTAssertGreaterThan(navy, checked * 9 / 10,
                             "\(checked - navy) of \(checked) pixels at the centre are not the theme's water")
    }

    @MainActor
    private func makeHarness(globe: Bool) throws -> OffscreenFrameHarness {
        let theme = ProtomapsBasemapTheme.night
            .layers { $0.water = Self.planeWater }
            .globeLayers { $0.water = Self.globeWater }
        var settings = ImmersiveMapSettings.default
            .mapStyle(ProtomapsBasemapMapStyle(theme: theme))
        settings.presentation.isGlobeEnabled = globe
        // The sun shades the globe by the subsolar point and the stars
        // twinkle with scene time: the pixels are read for the water's own
        // colour, so both are off, and the plane's air with them.
        settings.scene.starfield.starCount = 0
        settings.scene.globeLight.isEnabled = false
        settings.scene.atmosphere.isEnabled = false
        settings.scene.fog.isEnabled = false
        settings.labels.isEnabled = false
        return try OffscreenFrameHarness.makeOrSkip(settings: settings)
    }

    /// The frame once the fixture ocean is in under a camera over the
    /// equator at a globe zoom.
    @MainActor
    private func paintedFrame(_ harness: OffscreenFrameHarness) async throws -> RenderedFrame {
        harness.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: 0, longitudeDegrees: 0, zoom: 2.5))
        let baseline = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(0))
        let data = VectorTileFixture.fullCoverageTile(layerName: "water", properties: ["kind": "ocean"])
        let tiles = Set(WebMercatorTileScheme.neighbourhoodPyramid(latitude: 0, longitude: 0, maximumZoom: 3, radius: 2))
        for tile in tiles.sorted(by: { ($0.z, $0.x, $0.y) < ($1.z, $1.x, $1.y) }) {
            let didMaterialize = await harness.tileRenderStore.parseTile(tile: tile, data: data)
            XCTAssertTrue(didMaterialize, "Fixture tile \(tile.z)/\(tile.x)/\(tile.y) must parse")
        }
        return try await harness.renderUntilSettled(changedFrom: baseline,
                                                    startingAt: OffscreenFrameHarness.frameTime(1))
    }

    /// The pixels of the disc at the frame's centre, a tenth of the frame
    /// across, that satisfy `test`, and how many were read.
    private static func count(_ frame: RenderedFrame, where test: (RenderedFrame.Pixel) -> Bool) -> (Int, Int) {
        let center = frame.size / 2
        let radius = frame.size / 10
        var matching = 0
        var checked = 0
        for y in (center - radius) ... (center + radius) {
            for x in (center - radius) ... (center + radius)
            where (x - center) * (x - center) + (y - center) * (y - center) <= radius * radius {
                checked += 1
                if test(frame.pixel(x: x, y: y)) {
                    matching += 1
                }
            }
        }
        return (matching, checked)
    }

    private static func isGlobeWater(_ pixel: RenderedFrame.Pixel) -> Bool {
        pixel.red > 240 && pixel.green < 15 && pixel.blue > 240
    }

    private static func isPlaneWater(_ pixel: RenderedFrame.Pixel) -> Bool {
        pixel.red < 40 && pixel.green < 50 && pixel.blue > 50 && pixel.blue < 110
    }
}
