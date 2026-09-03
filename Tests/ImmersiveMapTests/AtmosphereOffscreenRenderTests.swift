// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

/// End-to-end: the atmosphere rings the globe's limb and nothing else. A
/// headless frame has no tiles, so the sphere's slots are unpainted and the
/// sky shows through them; the stars are removed so space is a flat dark
/// color the halo is measured against. Requires the compiled Metal library,
/// so it skips under `swift test` and runs in the xcodebuild workspace suite.
final class AtmosphereOffscreenRenderTests: XCTestCase {
    /// The claim of the feature: along the frame's center row the brightest
    /// blue sits at the limb (the halo's band), well above the level of
    /// space at the corners, blue-dominant, and decayed again before the
    /// frame's edge, so the atmosphere hugs the planet instead of tinting
    /// the whole sky.
    @MainActor
    func testHaloRingsTheLimb() async throws {
        let frame = try await renderGlobe(settings: settings())
        let center = frame.size / 2

        // The luminous planet body fills the disc (near-white); the halo
        // claim is about the ring OUTSIDE it. Find the body's edge along
        // the center row, then look for the halo beyond it.
        var bodyEnd = center
        for x in center ..< frame.size {
            let pixel = frame.pixel(x: x, y: center)
            if pixel.red > 200 && pixel.green > 200 && pixel.blue > 200 {
                bodyEnd = x
            }
        }
        XCTAssertLessThan(bodyEnd, frame.size - 12, "The glowing body ends inside the frame")

        var peakBlue = 0
        var peakX = bodyEnd + 3
        for x in (bodyEnd + 3) ..< frame.size {
            let blue = Int(frame.pixel(x: x, y: center).blue)
            if blue > peakBlue {
                peakBlue = blue
                peakX = x
            }
        }
        let cornerBlue = frame.corners.map { Int($0.blue) }.max() ?? 0
        let peak = frame.pixel(x: peakX, y: center)

        XCTAssertGreaterThan(peakBlue, cornerBlue + 40, "The halo band must stand out against space")
        XCTAssertGreaterThan(Int(peak.blue), Int(peak.red), "The halo is blue")
        XCTAssertLessThan(peakX, frame.size - 10, "The band is a ring at the limb, not a gradient into the frame edge")
        let edgeBlue = Int(frame.pixel(x: frame.size - 2, y: center).blue)
        XCTAssertLessThan(edgeBlue, peakBlue - 30, "The halo has mostly died out by the frame edge")
    }

    /// The atmosphere is painted around the globe, so transparent space
    /// drops it with the rest of the space décor: the center row of a
    /// tileless frame carries no coverage at all.
    @MainActor
    func testTransparentSpaceLeavesNoHalo() async throws {
        let frame = try await renderGlobe(settings: settings().transparentSpace())
        let center = frame.size / 2

        for x in 0 ..< frame.size {
            XCTAssertEqual(frame.pixel(x: x, y: center).alpha, 0,
                           "Nothing may be painted on the center row at x \(x)")
        }
    }

    // MARK: - Helpers

    private func settings() -> ImmersiveMapSettings {
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
}

/// The uniform layout is a binding contract with `Atmosphere` in
/// Atmosphere.metal: same offsets, same 128-byte stride.
final class AtmosphereUniformLayoutTests: XCTestCase {
    func testLayoutMirrorsTheShaderStruct() {
        XCTAssertEqual(MemoryLayout<AtmosphereUniform>.stride, 128 + 80)
        XCTAssertEqual(MemoryLayout<AtmosphereUniform>.offset(of: \.fog), 128)
        XCTAssertEqual(MemoryLayout<AtmosphereUniform>.offset(of: \.inverseViewProjection), 0)
        XCTAssertEqual(MemoryLayout<AtmosphereUniform>.offset(of: \.eye), 64)
        XCTAssertEqual(MemoryLayout<AtmosphereUniform>.offset(of: \.center), 80)
        XCTAssertEqual(MemoryLayout<AtmosphereUniform>.offset(of: \.color), 96)
        XCTAssertEqual(MemoryLayout<AtmosphereUniform>.offset(of: \.radius), 112)
        XCTAssertEqual(MemoryLayout<AtmosphereUniform>.offset(of: \.transition), 116)
        XCTAssertEqual(MemoryLayout<AtmosphereUniform>.offset(of: \.intensity), 120)
        XCTAssertEqual(MemoryLayout<AtmosphereUniform>.offset(of: \.thickness), 124)
    }

    /// GlobeBackdropUniform mirrors `GlobeBackdrop` in Atmosphere.metal.
    func testBackdropLayoutMirrorsTheShaderStruct() {
        XCTAssertEqual(MemoryLayout<GlobeBackdropUniform>.stride, 160)
        XCTAssertEqual(MemoryLayout<GlobeBackdropUniform>.offset(of: \.sphereClip), 0)
        XCTAssertEqual(MemoryLayout<GlobeBackdropUniform>.offset(of: \.sphereWorld), 64)
        XCTAssertEqual(MemoryLayout<GlobeBackdropUniform>.offset(of: \.eye), 128)
        XCTAssertEqual(MemoryLayout<GlobeBackdropUniform>.offset(of: \.fade), 144)
    }

    /// The unfurl fade: full on the resting sphere, gone past the halo's
    /// early window, so the body never lingers behind the unrolling map.
    func testBackdropFadeFollowsTheUnfurlWindow() {
        func fade(_ transition: Float) -> Float {
            let globe = GlobeUniform(panX: 0, panY: 0, radius: 1, transition: transition)
            return GlobeBackdropUniform.make(globe: globe,
                                             cameraMatrix: matrix_identity_float4x4,
                                             cameraEye: SIMD3<Float>(0, 0, 1)).fade
        }
        XCTAssertEqual(fade(0), 1)
        XCTAssertGreaterThan(fade(0.1), 0)
        XCTAssertLessThan(fade(0.1), 1)
        XCTAssertEqual(fade(GlobeBackdropUniform.transitionFadeEnd), 0)
        XCTAssertEqual(fade(1), 0)
    }
}
