// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// End-to-end: the atmosphere halo paints the space just outside the globe's
/// edge and nothing else. A headless frame has no tiles, so the globe is its
/// placeholder fill; the earth scene is off so the sun cannot move the halo,
/// and the stars are removed so the space around the planet is a flat color
/// the halo is measured against. Requires the compiled Metal library, so it
/// skips under `swift test` and runs in the xcodebuild workspace suite.
final class AtmosphereOffscreenRenderTests: XCTestCase {
    /// The claim of the feature: with the atmosphere on, the ring of space
    /// right outside the limb is brighter and bluer than plain space; with it
    /// off, that ring is plain space, and in both cases the far corners are.
    @MainActor
    func testHaloBrightensTheSpaceRightOutsideTheLimb() async throws {
        let bare = try await renderGlobe(settings: settings(atmosphere: false))
        let withHalo = try await renderGlobe(settings: settings(atmosphere: true))
        let ring = try XCTUnwrap(limbRing(in: bare), "The bare frame must show a globe with space around it")

        for point in ring {
            let bareSpace = bare.pixel(x: point.x, y: point.y)
            let halo = withHalo.pixel(x: point.x, y: point.y)
            XCTAssertTrue(isSpace(bareSpace), "Without the atmosphere the ring is space at \(point)")
            XCTAssertGreaterThan(Int(halo.blue), Int(bareSpace.blue) + 30, "The halo lights the ring at \(point)")
            XCTAssertGreaterThan(Int(halo.blue), Int(halo.red), "The halo is blue at \(point)")
        }
        for corner in withHalo.corners {
            XCTAssertTrue(isSpace(corner), "The halo has died out by the corners")
        }
        XCTAssertGreaterThan(withHalo.brightnessSum, bare.brightnessSum)
    }

    /// The halo dies out with distance: a ring well away from the limb (a
    /// good part of a globe radius out, as far as the frame allows) carries a
    /// small fraction of the lift the near ring gets, so the atmosphere hugs
    /// the planet instead of tinting the whole sky.
    @MainActor
    func testHaloDoesNotReachFarIntoSpace() async throws {
        let bare = try await renderGlobe(settings: settings(atmosphere: false))
        let withHalo = try await renderGlobe(settings: settings(atmosphere: true))
        let nearRing = try XCTUnwrap(limbRing(in: bare))
        let farRing = try XCTUnwrap(limbRing(in: bare, radiusScale: 1.7))

        for (near, far) in zip(nearRing, farRing) {
            let nearLift = Int(withHalo.pixel(x: near.x, y: near.y).blue) - Int(bare.pixel(x: near.x, y: near.y).blue)
            let farLift = Int(withHalo.pixel(x: far.x, y: far.y).blue) - Int(bare.pixel(x: far.x, y: far.y).blue)
            XCTAssertLessThan(Double(farLift), Double(nearLift) * 0.3, "The halo has mostly died out by \(far)")
            XCTAssertLessThanOrEqual(farLift, 24, "Only a faint glow reaches \(far)")
        }
    }

    /// The halo is painted in space, so transparent space drops it: with the
    /// atmosphere on, the frame carries exactly the coverage it carries with
    /// the atmosphere off. Nothing outside the globe may be painted there.
    @MainActor
    func testTransparentSpaceLeavesNoHalo() async throws {
        let bare = try await renderGlobe(settings: settings(atmosphere: false).transparentSpace())
        let withHalo = try await renderGlobe(settings: settings(atmosphere: true).transparentSpace())

        XCTAssertEqual(withHalo.count(where: { $0.alpha != 0 }), bare.count(where: { $0.alpha != 0 }))
        XCTAssertGreaterThan(bare.count(where: { $0.alpha != 0 }), 0, "The globe itself must be painted")
    }

    /// Off by setting, the atmosphere leaves the frame the way it was: no halo
    /// in space and no glow on the sphere, so the picture matches a globe that
    /// never had one.
    @MainActor
    func testAtmosphereOffLeavesTheSphereBare() async throws {
        let bare = try await renderGlobe(settings: settings(atmosphere: false))
        var zeroIntensity = settings(atmosphere: true)
        zeroIntensity.scene.atmosphere.intensity = 0
        let dimmed = try await renderGlobe(settings: zeroIntensity)

        // Zero intensity keeps the layer on and paints nothing: the same
        // picture as the atmosphere being off.
        XCTAssertEqual(dimmed, bare)
    }

    // MARK: - Helpers

    private func settings(atmosphere isEnabled: Bool) -> ImmersiveMapSettings {
        var settings = ImmersiveMapSettings.default
            .earthScene(isEnabled: false)
            .atmosphere(isEnabled: isEnabled)
        settings.scene.starfield.starCount = 0
        return settings
    }

    /// Space is the near-black blue the default clear color paints, and stays
    /// dark even with the nebula haze the starfield background adds.
    private func isSpace(_ pixel: RenderedFrame.Pixel) -> Bool {
        pixel.red < 40 && pixel.green < 50 && pixel.blue < 80 && pixel.alpha == 255
    }

    /// Renders one offscreen frame of the globe at zoom 1, centred in the frame.
    @MainActor
    private func renderGlobe(settings: ImmersiveMapSettings) async throws -> RenderedFrame {
        let harness = try OffscreenFrameHarness.makeOrSkip(settings: settings, size: 200)
        harness.setZoom(1.0)
        return try await harness.renderFrame()
    }

    /// Eight points on a ring outside the globe's edge, found by walking from
    /// the frame centre outward until the placeholder fill ends and space
    /// begins, on the frame that has no halo to blur that edge.
    ///
    /// At a `radiusScale` of 1 the ring sits three pixels past the edge, in
    /// the halo's bright band and clear of the antialiased limb itself; a
    /// larger scale moves it outward in multiples of the globe's on-screen
    /// radius, as far as the frame allows.
    private func limbRing(in frame: RenderedFrame, radiusScale: Double = 1.0) -> [(x: Int, y: Int)]? {
        let center = frame.size / 2
        var edge: Int?
        for offset in 1 ..< center {
            if isSpace(frame.pixel(x: center + offset, y: center)) {
                edge = offset
                break
            }
        }
        guard let edge, edge > 8, edge < center - 8 else {
            return nil
        }
        let radius = radiusScale == 1.0
            ? Double(edge) + 3.0
            : min(Double(edge) * radiusScale, Double(center) - 2.0)
        return (0 ..< 8).map { index in
            let angle = Double(index) * .pi / 4
            return (x: center + Int((radius * cos(angle)).rounded()),
                    y: center + Int((radius * sin(angle)).rounded()))
        }
    }
}
