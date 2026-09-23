// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The CPU mirror of `tileStyleFade` answers two questions per run and
/// frame: fade exactly 1 (draw opaque) and fade exactly 0 (skip entirely).
/// Its progress must match the shader's and the public type's curve at the
/// ends of every fade.
final class TileStyleFadeMathTests: XCTestCase {
    private func uniform(_ cameraZoom: Float) -> TileOverviewFadeUniform {
        TileOverviewFadeUniform(pixelsPerPoint: 2, cameraZoom: cameraZoom)
    }

    func testNoFadeIsAlwaysOneAndNeverZero() {
        let none = ImmersiveMapZoomFade.none.shaderPair
        for zoom: Float in [0, 0.5, 7, 22] {
            XCTAssertTrue(TileStyleFadeMath.fadeIsOne(zoomFade: none, overviewFade: uniform(zoom)), "\(zoom)")
            XCTAssertFalse(TileStyleFadeMath.fadeIsZero(zoomFade: none, overviewFade: uniform(zoom)), "\(zoom)")
        }
    }

    func testAFadeInIsZeroBelowItsRangeAndOneAbove() {
        let fade = ImmersiveMapZoomFade.fadeIn(from: 15, to: 15.4).shaderPair
        XCTAssertTrue(TileStyleFadeMath.fadeIsZero(zoomFade: fade, overviewFade: uniform(14)))
        XCTAssertTrue(TileStyleFadeMath.fadeIsZero(zoomFade: fade, overviewFade: uniform(15)))
        XCTAssertFalse(TileStyleFadeMath.fadeIsZero(zoomFade: fade, overviewFade: uniform(15.2)))
        XCTAssertFalse(TileStyleFadeMath.fadeIsOne(zoomFade: fade, overviewFade: uniform(15.2)))
        XCTAssertTrue(TileStyleFadeMath.fadeIsOne(zoomFade: fade, overviewFade: uniform(15.4)))
        XCTAssertTrue(TileStyleFadeMath.fadeIsOne(zoomFade: fade, overviewFade: uniform(18)))
    }

    func testAFadeOutIsOneBelowItsRangeAndZeroAbove() {
        let fade = ImmersiveMapZoomFade.fadeOut(from: 7, to: 8).shaderPair
        XCTAssertTrue(TileStyleFadeMath.fadeIsOne(zoomFade: fade, overviewFade: uniform(3)))
        XCTAssertTrue(TileStyleFadeMath.fadeIsOne(zoomFade: fade, overviewFade: uniform(7)))
        XCTAssertFalse(TileStyleFadeMath.fadeIsOne(zoomFade: fade, overviewFade: uniform(7.5)))
        XCTAssertFalse(TileStyleFadeMath.fadeIsZero(zoomFade: fade, overviewFade: uniform(7.5)))
        XCTAssertTrue(TileStyleFadeMath.fadeIsZero(zoomFade: fade, overviewFade: uniform(8)))
    }

    /// The drawer's opaque and skip decisions follow the same curve the
    /// public type (and the shader) evaluate.
    func testTheMirrorAgreesWithTheCurveEverywhere() {
        let fades: [ImmersiveMapZoomFade] = [.fadeIn(from: 0, to: 1), .fadeIn(from: 5, to: 6),
                                             .fadeOut(from: 7, to: 8), .fadeIn(from: 15, to: 15.4)]
        for fade in fades {
            for step in 0...200 {
                let zoom = Double(step) * 0.1
                let alpha = fade.alpha(atZoom: zoom)
                let frame = uniform(Float(zoom))
                XCTAssertEqual(TileStyleFadeMath.fadeIsOne(zoomFade: fade.shaderPair, overviewFade: frame),
                               alpha >= 1, "\(fade) at \(zoom)")
                XCTAssertEqual(TileStyleFadeMath.fadeIsZero(zoomFade: fade.shaderPair, overviewFade: frame),
                               alpha <= 0, "\(fade) at \(zoom)")
            }
        }
    }
}
