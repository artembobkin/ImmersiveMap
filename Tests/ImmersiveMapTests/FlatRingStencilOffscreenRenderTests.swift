// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// End-to-end contract of the flat map's rings: a tile of a far ring draws
/// on its own ring and on the farther ones, and never on a nearer ring,
/// however far its geometry reaches and whatever the nearer ring paints
/// there (`RingStencilRenderSubsystem`, `FlatTileStencilPacking`). The
/// camera looks straight down at the centre of a z14 tile under the
/// default rules, so the ring of z14 tiles around it fills the middle of
/// the frame and the ring of z13 tiles beyond shows at the edges. The z14
/// tiles of the near ring are loaded with nothing to paint, and the z13
/// tile west of them, painted magenta, reaches a z14 column into the near
/// ring: that column must stay the clear colour. Requires the compiled
/// Metal library, so it skips under `swift test` and runs in the
/// xcodebuild workspace suite.
final class FlatRingStencilOffscreenRenderTests: XCTestCase {
    /// A colour that appears nowhere else in the map.
    private static let fixtureWater = SIMD4<Float>(1, 0, 1, 1)

    /// The tile the camera looks at, its z13 parent's west neighbour and
    /// the z14 column of the near ring that neighbour reaches into.
    private static let lookAt = Tile(x: 9908, y: 5140, z: 14)
    private static let farTile = Tile(x: 4953, y: 2570, z: 13)
    private static let reachedColumn = [Tile(x: 9907, y: 5140, z: 14), Tile(x: 9907, y: 5141, z: 14)]
    /// The frame: wide enough to show the far ring at zoom 14 whatever the
    /// pixel size of a tile.
    private static let frameSize = 2048

    @MainActor
    func testAFarRingsTileNeverPaintsTheNearRing() async throws {
        // Without the near ring's tiles the far tile stands in for the
        // column it reaches, so its magenta runs east to the look-at tile's
        // west edge: the fixture is in view and reachable.
        let standingIn = try await render(nearRingLoaded: false)
        let standInEnd = magentaEastEnd(in: standingIn)
        XCTAssertGreaterThan(standInEnd, 0, "The far tile must be in view west of the look-at tile")
        XCTAssertLessThan(standInEnd, Self.frameSize / 2, "The look-at tile paints nothing")
        // The magenta ends half a tile west of the frame's centre, so a
        // tile is the frame less twice the end.
        let tileWidth = Self.frameSize - 2 * standInEnd
        XCTAssertGreaterThan(tileWidth, 32, "A tile is on screen")

        // With the near ring's tiles loaded, painting nothing, the far tile
        // draws only on its own ring: the column it reaches stays the clear
        // colour, and its magenta ends a tile further west.
        let ringed = try await render(nearRingLoaded: true)
        let ringedEnd = magentaEastEnd(in: ringed)
        XCTAssertGreaterThan(ringedEnd, 0, "On its own ring the far tile paints")
        XCTAssertEqual(Double(ringedEnd), Double(standInEnd - tileWidth), accuracy: 4,
                       "The far tile stops at the near ring's square: \(ringedEnd) against \(standInEnd) as a stand-in")
        let row = Self.frameSize / 2
        for x in stride(from: ringedEnd + 8, to: Self.frameSize / 2, by: 16) {
            XCTAssertFalse(isFixtureWater(ringed.pixel(x: x, y: row)),
                           "No magenta on the near ring at \(x)")
        }
    }

    // MARK: - Helpers

    /// The frame with the far tile loaded, and the near ring's tiles loaded
    /// with nothing to paint or not at all.
    @MainActor
    private func render(nearRingLoaded: Bool) async throws -> RenderedFrame {
        let harness = try makeHarness()
        let centre = (x: (Double(Self.lookAt.x) + 0.5) / Double(1 << Self.lookAt.z),
                      y: (Double(Self.lookAt.y) + 0.5) / Double(1 << Self.lookAt.z))
        let latitude = atan(sinh(Double.pi * (1.0 - 2.0 * centre.y))) * 180.0 / .pi
        let longitude = centre.x * 360.0 - 180.0
        harness.setCameraPosition(ImmersiveMapCameraPosition(latitudeDegrees: latitude,
                                                              longitudeDegrees: longitude,
                                                              zoom: 14))
        let baseline = try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(0))

        let water = VectorTileFixture.fullCoverageTile(layerName: "water", properties: ["kind": "ocean"])
        // A layer no schema knows: the tile parses, is resident and paints
        // nothing.
        let nothing = VectorTileFixture.fullCoverageTile(layerName: "nothing", properties: ["kind": "nothing"])
        let farLoaded = await harness.tileRenderStore.parseTile(tile: Self.farTile, data: water)
        XCTAssertTrue(farLoaded, "The far fixture tile must parse")
        if nearRingLoaded {
            for dx in -1 ... 1 {
                for dy in -1 ... 1 {
                    let tile = Tile(x: Self.lookAt.x + dx, y: Self.lookAt.y + dy, z: Self.lookAt.z)
                    let loaded = await harness.tileRenderStore.parseTile(tile: tile, data: nothing)
                    XCTAssertTrue(loaded, "The near ring's fixture tile must parse")
                }
            }
            XCTAssertTrue(Self.reachedColumn.allSatisfy { abs($0.x - Self.lookAt.x) <= 1 && abs($0.y - Self.lookAt.y) <= 1 },
                          "The reached column lies in the near ring")
        }
        return try await harness.renderUntilSettled(changedFrom: baseline,
                                                    startingAt: OffscreenFrameHarness.frameTime(1))
    }

    /// Where the magenta ends along the middle row, from the west: one
    /// past the easternmost magenta pixel in the frame's west half, 0 with
    /// none. The frame's west edge may lie past the far ring's own tiles,
    /// which are not loaded, so the run is measured by its end.
    private func magentaEastEnd(in frame: RenderedFrame) -> Int {
        let row = Self.frameSize / 2
        var end = 0
        for x in 0 ..< Self.frameSize / 2 where isFixtureWater(frame.pixel(x: x, y: row)) {
            end = x + 1
        }
        return end
    }

    @MainActor
    private func makeHarness() throws -> OffscreenFrameHarness {
        let configuration = ProtomapsBasemapTheme.default
            .layers { layers in
                layers.water = Self.fixtureWater
            }
        var settings = ImmersiveMapSettings.default
            .mapStyle(ProtomapsBasemapMapStyle(theme: configuration))
        settings.scene.starfield.starCount = 0
        settings.scene.shadows.isEnabled = false
        settings.scene.fog.isEnabled = false
        settings.scene.groundFog.isEnabled = false
        settings.labels.isEnabled = false
        return try OffscreenFrameHarness.makeOrSkip(settings: settings, size: Self.frameSize)
    }

    private func isFixtureWater(_ pixel: RenderedFrame.Pixel) -> Bool {
        pixel.red > 200 && pixel.green < 60 && pixel.blue > 200
    }
}
