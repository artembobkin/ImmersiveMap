// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// End-to-end: with transparent space a headless frame must come back with the
/// area outside the globe unpainted while the globe itself keeps its own
/// coverage. The globe is covered with fixture water tiles, since a slot no
/// tile has painted is left unpainted on purpose. Requires the compiled
/// Metal library, so it skips under `swift test` and runs in the xcodebuild
/// workspace suite.
final class TransparentSpaceOffscreenRenderTests: XCTestCase {
    /// The space background and the stars come from the starfield layer, so
    /// if either still painted, the corners would come back opaque.
    @MainActor
    func testTransparentSpaceLeavesTheAreaOutsideTheGlobeUnpainted() async throws {
        let settings = ImmersiveMapSettings.default
            .transparentSpace()
        let frame = try await renderFrame(settings: settings)

        for corner in frame.corners {
            XCTAssertEqual(corner.alpha, 0, "Nothing outside the globe may be painted")
        }
        XCTAssertEqual(frame.pixel(x: frame.size / 2, y: frame.size / 2).alpha, 255,
                       "The globe itself must stay opaque")
    }

    /// The default globe paints space, and that must not change.
    ///
    /// Every pixel, not the corners: a transparent band between the corners
    /// and the limb is exactly the kind of hole a corner check would miss.
    @MainActor
    func testOpaqueSpacePaintsTheWholeFrame() async throws {
        // No settling: the stars twinkle with scene time, so the default
        // frame never stops changing, and the claim holds with or without
        // the tiles in it.
        let frame = try await renderFrame(settings: .default, settles: false)

        XCTAssertEqual(frame.count(where: { $0.alpha != 255 }), 0,
                       "The default map must leave no pixel unpainted")
    }

    /// FXAA writes the drawable in its own pass, so it is the one place where a
    /// forced alpha of 1 would silently make the frame opaque again.
    @MainActor
    func testTransparentSpaceSurvivesPostProcessing() async throws {
        var settings = ImmersiveMapSettings.default.transparentSpace()
        settings.postProcessing = ImmersiveMapSettings.PostProcessingSettings(fxaaEnabled: true)
        let frame = try await renderFrame(settings: settings)

        for corner in frame.corners {
            XCTAssertEqual(corner.alpha, 0, "FXAA must carry the frame alpha through")
        }
        XCTAssertEqual(frame.pixel(x: frame.size / 2, y: frame.size / 2).alpha, 255)
    }

    // MARK: - Helpers

    /// Renders one offscreen frame of a globe at zoom 1, its surface painted
    /// by water tiles at the three coarsest zooms.
    @MainActor
    private func renderFrame(settings: ImmersiveMapSettings, settles: Bool = true) async throws -> RenderedFrame {
        let harness = try OffscreenFrameHarness.makeOrSkip(settings: settings)
        harness.setZoom(1.0)
        let baseline = try await harness.renderFrame()
        let water = VectorTileFixture.fullCoverageTile(layerName: "water", properties: ["class": "ocean"])
        for z in 0 ... 2 {
            for x in 0 ..< (1 << z) {
                for y in 0 ..< (1 << z) {
                    let loaded = await harness.tileRenderStore.parseTile(tile: Tile(x: x, y: y, z: z), data: water)
                    XCTAssertTrue(loaded, "The fixture tile \(z)/\(x)/\(y) must parse")
                }
            }
        }
        guard settles else {
            return try await harness.renderFrame(at: OffscreenFrameHarness.frameTime(1))
        }
        return try await harness.renderUntilSettled(changedFrom: baseline,
                                                    startingAt: OffscreenFrameHarness.frameTime(1))
    }
}
