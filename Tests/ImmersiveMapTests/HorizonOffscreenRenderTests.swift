// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// End-to-end: the air around the surface's edge. On the globe the
/// atmosphere rings the limb, the feather stays when the atmosphere is off,
/// and transparent space gets nothing; on the tilted flat map the ground
/// fogs into the clear colour at the horizon line and stays byte-clean
/// under the camera. A headless globe frame has no tiles, so the sphere's
/// slots are unpainted and space shows through them; the stars are removed
/// so space is a flat dark colour the halo is measured against. Requires
/// the compiled Metal library, so it skips under `swift test` and runs in
/// the xcodebuild workspace suite.
final class HorizonOffscreenRenderTests: XCTestCase {
    /// A colour that appears nowhere else in the map.
    private static let fixtureWater = SIMD4<Float>(1, 0, 1, 1)
    private static let paperClearColor = SIMD4<Double>(0.973, 0.965, 0.941, 1)
    private static let greenClearColor = SIMD4<Double>(0.1, 0.9, 0.2, 1)

    // MARK: - The globe

    /// Along the frame's centre row the brightest blue sits at the limb (the
    /// halo's band), well above the level of space at the corners, blue
    /// dominant, and decayed again before the frame's edge, so the
    /// atmosphere hugs the planet instead of tinting the whole sky.
    @MainActor
    func testTheHaloRingsTheLimb() async throws {
        let frame = try await renderGlobe(settings: globeSettings())
        let center = frame.size / 2
        let (peakX, peakBlue) = peak(in: frame, row: center) { Int($0.blue) }
        let cornerBlue = frame.corners.map { Int($0.blue) }.max() ?? 0
        let peakPixel = frame.pixel(x: peakX, y: center)

        XCTAssertGreaterThan(peakBlue, cornerBlue + 40, "The halo band must stand out against space")
        XCTAssertGreaterThan(Int(peakPixel.blue), Int(peakPixel.red), "The halo is blue")
        XCTAssertLessThanOrEqual(abs(peakX - Self.limbX(size: frame.size)), 4,
                                 "The band peaks at the analytic limb, not on a circle drawn on screen")
        let edgeBlue = Int(frame.pixel(x: frame.size - 2, y: center).blue)
        XCTAssertLessThan(edgeBlue, peakBlue - 30, "The halo has mostly died out by the frame edge")
    }

    /// With the atmosphere off the limb still wears its feather: a glow a
    /// couple of pixels wide, in the fog colour, gone a few pixels away on
    /// either side. It is what hides the staircase of the mesh edge.
    @MainActor
    func testTheFeatherStaysWithTheAtmosphereOff() async throws {
        let frame = try await renderGlobe(settings: globeSettings().atmosphere(isEnabled: false))
        let center = frame.size / 2
        let (peakX, peakBrightness) = peak(in: frame, row: center) { Int($0.red) + Int($0.green) + Int($0.blue) }
        let space = frame.corners[0]
        let spaceBrightness = Int(space.red) + Int(space.green) + Int(space.blue)

        XCTAssertGreaterThan(peakBrightness, spaceBrightness + 150, "The feather glows at the limb")
        XCTAssertLessThanOrEqual(abs(peakX - Self.limbX(size: frame.size)), 3, "The feather sits on the analytic limb")
        let peakPixel = frame.pixel(x: peakX, y: center)
        XCTAssertLessThan(abs(Int(peakPixel.red) - Int(peakPixel.blue)), 40, "Off, the feather is the fog colour, not blue")
        for offset in [-8, 8] {
            let away = frame.pixel(x: peakX + offset, y: center)
            XCTAssertLessThanOrEqual(abs(Int(away.blue) - Int(space.blue)), 3, "Space again \(offset) px from the limb")
            XCTAssertLessThanOrEqual(abs(Int(away.red) - Int(space.red)), 3, "Space again \(offset) px from the limb")
        }
    }

    /// Everything around the globe is painted in space, so transparent space
    /// drops it: the centre row of a tileless frame carries no coverage.
    @MainActor
    func testTransparentSpaceLeavesNoAir() async throws {
        let frame = try await renderGlobe(settings: globeSettings().transparentSpace())
        let center = frame.size / 2
        for x in 0 ..< frame.size {
            XCTAssertEqual(frame.pixel(x: x, y: center).alpha, 0, "Nothing may be painted on the centre row at x \(x)")
        }
    }

    // MARK: - The flat map

    /// Pitched almost to the horizon over a magenta world: above the line
    /// the sky is the clear colour, just under it the ground is fogged into
    /// that same colour, a few rows further the fog thins, and the bottom of
    /// the frame is the bare fixture colour. Rendered twice with different
    /// clear colours, so the fog's colour is pinned by what changes and the
    /// byte-clean ground by what does not.
    @MainActor
    func testTheFlatHorizonWearsTheFogBand() async throws {
        let paper = try await renderTiltedPlane(clearColor: Self.paperClearColor)
        let green = try await renderTiltedPlane(clearColor: Self.greenClearColor)
        let size = paper.size
        let column = size / 2
        let paperClear = Self.pixel(of: Self.paperClearColor)
        let greenClear = Self.pixel(of: Self.greenClearColor)

        XCTAssertLessThanOrEqual(Self.distance(paper.pixel(x: column, y: 0), paperClear), 6, "The sky is the clear colour")
        XCTAssertLessThanOrEqual(Self.distance(green.pixel(x: column, y: 0), greenClear), 6, "The sky is the clear colour")

        // The horizon line is where the paper frame first leaves its clear
        // colour going down; the fog saturates to it for a short way under
        // the line, so the release comes a few rows below the geometric line.
        guard let releaseRow = (1 ..< size).first(where: { Self.distance(paper.pixel(x: column, y: $0), paperClear) > 6 }) else {
            return XCTFail("The ground never appeared below the horizon")
        }
        XCTAssertTrue((10 ... 50).contains(releaseRow), "The horizon sits near the top of a frame pitched this far: row \(releaseRow)")
        XCTAssertLessThanOrEqual(Self.distance(green.pixel(x: column, y: releaseRow - 1), greenClear), 6,
                                 "Just under the line the ground is fogged into the frame's own clear colour")
        let bandRows = (releaseRow ..< min(releaseRow + 25, size)).filter {
            Self.distance(paper.pixel(x: column, y: $0), green.pixel(x: column, y: $0)) > 6
        }
        XCTAssertGreaterThanOrEqual(bandRows.count, 3, "The fog thins over a band of rows under the line")

        for y in (size * 3 / 4) ..< size {
            XCTAssertEqual(paper.pixel(x: column, y: y), green.pixel(x: column, y: y),
                           "Under the camera the map is byte-clean of fog at row \(y)")
        }
        XCTAssertTrue(Self.isFixtureWater(paper.pixel(x: column, y: size - 1)), "The near ground is the bare fixture colour")
    }

    // MARK: - Helpers

    private func globeSettings() -> ImmersiveMapSettings {
        var settings = ImmersiveMapSettings.default
        settings.scene.starfield.starCount = 0
        return settings
    }

    /// Renders one offscreen frame of the globe at zoom 1, centred in the frame.
    @MainActor
    private func renderGlobe(settings: ImmersiveMapSettings) async throws -> RenderedFrame {
        let harness = try OffscreenFrameHarness.makeOrSkip(settings: settings, size: 200)
        harness.setZoom(1.0)
        return try await harness.renderFrame()
    }

    /// The limb's column on the centre row at zoom 1: the eye sits one unit
    /// from the view centre over a sphere of radius 0.28, so the limb is
    /// `asin(R / d)` off the axis in a 45 degree field of view.
    private static func limbX(size: Int) -> Int {
        let radius = 0.14 * 2.0
        let limbAngle = asin(radius / (1 + radius))
        let ndc = tan(limbAngle) / tan(Double.pi / 8)
        return Int((Double(size) / 2 * (1 + ndc)).rounded())
    }

    private func peak(in frame: RenderedFrame, row: Int, by value: (RenderedFrame.Pixel) -> Int) -> (x: Int, value: Int) {
        var peakValue = Int.min
        var peakX = frame.size / 2 + 1
        for x in (frame.size / 2 + 1) ..< frame.size {
            let candidate = value(frame.pixel(x: x, y: row))
            if candidate > peakValue {
                peakValue = candidate
                peakX = x
            }
        }
        return (peakX, peakValue)
    }

    /// A magenta world tilted almost to the horizon at zoom 10, with every
    /// tile the frame could ask for handed to the store (the near zooms
    /// around the camera, the coarse zooms everywhere, since the far range
    /// and the horizon backdrop draw whatever ancestor is loaded).
    @MainActor
    private func renderTiltedPlane(clearColor: SIMD4<Double>) async throws -> RenderedFrame {
        let configuration = ImmersiveMapTilesDefaultMapStyleConfiguration.immersiveMapTilesDefault
            .globalLandcover { landcover in
                landcover.water = Self.fixtureWater
            }
            .layers { layers in
                layers.water = Self.fixtureWater
            }
        var settings = ImmersiveMapSettings.default
            .mapStyle(ImmersiveMapTilesMapStyle(configuration: configuration))
        settings.scene.starfield.starCount = 0
        settings.scene.shadows.isEnabled = false
        settings.scene.mapClearColor = clearColor
        let harness = try OffscreenFrameHarness.makeOrSkip(settings: settings, size: 200)
        let latitude = 48.0
        let longitude = 10.0
        harness.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: latitude,
                                                              longitudeDegrees: longitude,
                                                              zoom: 10,
                                                              pitch: 1.25))
        let baseline = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(0))

        let data = VectorTileFixture.fullCoverageTile(layerName: "water", properties: ["class": "ocean"])
            + VectorTileFixture.fullCoverageTile(layerName: "globallandcover", properties: ["class": "water"])
        for zoom in 0 ... 10 {
            let tiles = WebMercatorTileScheme.neighbourhoodPyramid(latitude: latitude,
                                                                   longitude: longitude,
                                                                   maximumZoom: zoom,
                                                                   radius: zoom <= 3 ? 8 : 2)
                .filter { $0.z == zoom }
            for tile in tiles {
                let loaded = await harness.tileRenderStore.parseTile(tile: tile, data: data)
                XCTAssertTrue(loaded, "The fixture tile \(tile) must parse")
            }
        }
        return try await harness.renderUntilSettled(changedFrom: baseline,
                                                    startingAt: OffscreenFrameHarness.frameTime(1))
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

    private static func isFixtureWater(_ pixel: RenderedFrame.Pixel) -> Bool {
        pixel.red > 200 && pixel.green < 60 && pixel.blue > 200
    }
}
