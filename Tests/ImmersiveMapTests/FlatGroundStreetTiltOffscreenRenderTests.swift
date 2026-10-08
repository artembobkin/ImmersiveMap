// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The ground at a street tilt, the camera up to seven levels past the
/// tiles' zoom: a z15 tile blown up to many screens, its fills running
/// behind the camera and cut at the near plane. Every pixel of the near
/// ground has to show the fill that covers it: a fill that lies over the
/// whole tile covers the whole frame, and the map colour under it never
/// shows through, in no frame of a slow pan. The z15 tiles carry their
/// ground flattened (`GroundFlattening`, on by default from z15), so the
/// fills have no rank order the near plane's cut could break, which is
/// what holds at the deep zooms. The layered ground holds a level past
/// the tiles' zoom and no further (Tile.metal). Requires the compiled
/// Metal library, so it skips under `swift test` and runs in the
/// xcodebuild workspace suite.
final class FlatGroundStreetTiltOffscreenRenderTests: XCTestCase {
    /// A map colour that appears nowhere else in the frame: what the near
    /// ground shows wherever the park fill over it fails.
    private static let fixtureMap = SIMD4<Float>(1, 0, 1, 1)

    private static let tile = Tile(x: 9651, y: 12319, z: 15)

    @MainActor
    func testTheNearGroundShowsItsFillWholeAtAStreetTilt() async throws {
        let harness = try makeHarness()
        let parkData = VectorTileFixture.fullCoverageTile(layerName: "landuse",
                                                          properties: ["kind": "park"])
        // The tile and its neighbours: the fill reaches every edge of the
        // frame whatever the bearing.
        for dx in -1 ... 1 {
            for dy in -1 ... 1 {
                let neighbour = Tile(x: Self.tile.x + dx, y: Self.tile.y + dy, z: Self.tile.z)
                let loaded = await harness.tileRenderStore.parseTile(tile: neighbour, data: parkData)
                XCTAssertTrue(loaded, "The park fixture tile must parse")
            }
        }

        let centerUv = (x: (Double(Self.tile.x) + 0.5) / Double(1 << Self.tile.z),
                        y: (Double(Self.tile.y) + 0.5) / Double(1 << Self.tile.z))
        let latitude = atan(sinh(Double.pi * (1.0 - 2.0 * centerUv.y))) * 180.0 / .pi
        let longitude = centerUv.x * 360.0 - 180.0
        // From half a level past the tiles' zoom to the street: a layered
        // ground would lose pixels of the near ground from 16.5 and blocks
        // of it from 17.
        for (zoomIndex, zoom) in [15.5, 16.0, 17.0, 19.6, 22.0].enumerated() {
            var zoomLeak = 0
            for frameIndex in 0 ..< 12 {
                // A slow pan at the street tilt: the cut vertices move a little
                // every frame, which is what makes the near ground flicker.
                let bearing = -0.7 + Float(frameIndex) * 0.004
                harness.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: latitude + Double(frameIndex) * 2e-7,
                                                                      longitudeDegrees: longitude,
                                                                      zoom: zoom,
                                                                      bearing: bearing,
                                                                      pitch: 85 * .pi / 180))
                let frame = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(zoomIndex * 12 + frameIndex))
                // The lower half of the frame is the near ground, under the
                // horizon's band and the far tiles.
                var leak = 0
                for y in (frame.size / 2) ..< frame.size {
                    for x in 0 ..< frame.size where Self.isFixtureMap(frame.pixel(x: x, y: y)) {
                        leak += 1
                    }
                }
                zoomLeak = max(zoomLeak, leak)
            }
            XCTAssertEqual(zoomLeak, 0, "Zoom \(zoom): the near ground shows the map colour through the park")
        }
    }

    @MainActor
    private func makeHarness() throws -> OffscreenFrameHarness {
        let configuration = ProtomapsBasemapTheme.default
            .layers { layers in
                layers.land = Self.fixtureMap
            }
        var settings = ImmersiveMapSettings.default
            .mapStyle(ProtomapsBasemapMapStyle(theme: configuration))
        settings.camera.maximumZoom = 22
        settings.scene.starfield.starCount = 0
        settings.scene.shadows.isEnabled = false
        settings.scene.fog.isEnabled = false
        settings.labels.isEnabled = false
        return try OffscreenFrameHarness.makeOrSkip(settings: settings, size: 512)
    }

    private static func isFixtureMap(_ pixel: RenderedFrame.Pixel) -> Bool {
        pixel.red > 200 && pixel.green < 60 && pixel.blue > 200
    }
}
