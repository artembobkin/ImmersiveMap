// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The public zoom fade: a layer drawn in full on one side of a zoom range,
/// not at all on the other, a smoothstep in between, and the pair the
/// shader reads.
final class ImmersiveMapZoomFadeTests: XCTestCase {
    func testNoFadeDrawsInFullAtEveryZoom() {
        for zoom in [0.0, 0.3, 7.5, 22] {
            XCTAssertEqual(ImmersiveMapZoomFade.none.alpha(atZoom: zoom), 1, "\(zoom)")
        }
    }

    func testAFadeInRisesFromNothingToFull() {
        let fade = ImmersiveMapZoomFade.fadeIn(from: 7, to: 8)
        XCTAssertEqual(fade.alpha(atZoom: 3), 0)
        XCTAssertEqual(fade.alpha(atZoom: 7), 0)
        XCTAssertEqual(fade.alpha(atZoom: 7.5), 0.5, accuracy: 1e-6)
        XCTAssertEqual(fade.alpha(atZoom: 8), 1)
        XCTAssertEqual(fade.alpha(atZoom: 12), 1)
        XCTAssertEqual(fade.shaderPair, SIMD2<Float>(7, 8))
    }

    func testAFadeOutFallsFromFullToNothing() {
        let fade = ImmersiveMapZoomFade.fadeOut(from: 7, to: 8)
        XCTAssertEqual(fade.alpha(atZoom: 3), 1)
        XCTAssertEqual(fade.alpha(atZoom: 7), 1)
        XCTAssertEqual(fade.alpha(atZoom: 7.5), 0.5, accuracy: 1e-6)
        XCTAssertEqual(fade.alpha(atZoom: 8), 0)
        XCTAssertEqual(fade.alpha(atZoom: 12), 0)
        XCTAssertEqual(fade.shaderPair, SIMD2<Float>(8, 7))
    }

    /// The curve is a smoothstep, not a ramp: flat at both ends, so a fade
    /// starts and settles without a visible kink.
    func testTheCurveIsASmoothstep() {
        let fade = ImmersiveMapZoomFade.fadeIn(from: 0, to: 1)
        XCTAssertEqual(fade.alpha(atZoom: 0.25), 0.15625, accuracy: 1e-6)
        XCTAssertEqual(fade.alpha(atZoom: 0.75), 0.84375, accuracy: 1e-6)
        let out = ImmersiveMapZoomFade.fadeOut(from: 0, to: 1)
        XCTAssertEqual(fade.alpha(atZoom: 0.3) + out.alpha(atZoom: 0.3), 1, accuracy: 1e-6,
                       "A fade in and a fade out over one range cross-fade to a constant sum")
    }

    /// Any transition length, fractional ends included.
    func testTheRangeMayBeAnyLength() {
        let short = ImmersiveMapZoomFade.fadeIn(from: 15, to: 15.4)
        XCTAssertEqual(short.alpha(atZoom: 15.2), 0.5, accuracy: 1e-6)
        let long = ImmersiveMapZoomFade.fadeOut(from: 4, to: 10)
        XCTAssertEqual(long.alpha(atZoom: 7), 0.5, accuracy: 1e-6)
    }

    func testTheCPUMirrorAgreesWithThePublicCurve() {
        let fade = ImmersiveMapZoomFade.fadeOut(from: 7, to: 8)
        let frame = TileOverviewFadeUniform(pixelsPerPoint: 1, cameraZoom: 7.25)
        let progress = TileStyleFadeMath.progress(zoomFade: fade.shaderPair, overviewFade: frame)
        XCTAssertEqual(progress * progress * (3 - 2 * progress), fade.alpha(atZoom: 7.25), accuracy: 1e-6)
    }
}
