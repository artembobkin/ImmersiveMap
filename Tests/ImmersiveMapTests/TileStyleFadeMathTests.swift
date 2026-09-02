// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The CPU mirror of `tileStyleFade` answers two questions per run and
/// frame: fade exactly 1 (draw opaque) and fade exactly 0 (skip entirely).
/// The bands and thresholds must match the shader's, band for band.
final class TileStyleFadeMathTests: XCTestCase {
    private func fade(overview: Float = 1, road: Float = 1, landuse: Float = 1,
                      marking: Float = 1, cameraZoom: Float = 10) -> TileOverviewFadeUniform {
        TileOverviewFadeUniform(overviewAlpha: overview,
                                roadAlpha: road,
                                landuseAlpha: landuse,
                                pixelsPerPoint: 2,
                                roadSurfaceBlend: 0,
                                roadMarkingAlpha: marking,
                                cameraZoom: cameraZoom)
    }

    func testEachBandReadsItsOwnAlpha() {
        // Band masks: 1 overview, 2 roads, 3 landuse, 4 markings.
        XCTAssertTrue(TileStyleFadeMath.fadeIsZero(mask: 1, overviewFade: fade(overview: 0)))
        XCTAssertFalse(TileStyleFadeMath.fadeIsZero(mask: 1, overviewFade: fade(overview: 0.01)))
        XCTAssertTrue(TileStyleFadeMath.fadeIsZero(mask: 2, overviewFade: fade(road: 0)))
        XCTAssertFalse(TileStyleFadeMath.fadeIsZero(mask: 2, overviewFade: fade(road: 0.5)))
        XCTAssertTrue(TileStyleFadeMath.fadeIsZero(mask: 3, overviewFade: fade(landuse: 0)))
        XCTAssertTrue(TileStyleFadeMath.fadeIsZero(mask: 4, overviewFade: fade(marking: 0)))
        // No mask: never faded, in either direction.
        XCTAssertFalse(TileStyleFadeMath.fadeIsZero(mask: 0, overviewFade: fade(overview: 0, road: 0)))
        XCTAssertTrue(TileStyleFadeMath.fadeIsOne(mask: 0, overviewFade: fade(overview: 0)))
    }

    func testClassFadeFollowsTheCameraZoom() {
        // Mask 10 + startZoom: nothing below the start, full one level past.
        let mask: Float = 14 // class fades in from zoom 4
        XCTAssertTrue(TileStyleFadeMath.fadeIsZero(mask: mask, overviewFade: fade(cameraZoom: 3.9)))
        XCTAssertTrue(TileStyleFadeMath.fadeIsZero(mask: mask, overviewFade: fade(cameraZoom: 4.0)))
        XCTAssertFalse(TileStyleFadeMath.fadeIsZero(mask: mask, overviewFade: fade(cameraZoom: 4.3)))
        XCTAssertFalse(TileStyleFadeMath.fadeIsOne(mask: mask, overviewFade: fade(cameraZoom: 4.3)))
        XCTAssertTrue(TileStyleFadeMath.fadeIsOne(mask: mask, overviewFade: fade(cameraZoom: 5.0)))
    }

    func testTheTwoQuestionsNeverBothHold() {
        for mask: Float in [0, 1, 2, 3, 4, 12] {
            for alpha: Float in [0, 0.5, 1] {
                let uniform = fade(overview: alpha, road: alpha, landuse: alpha,
                                   marking: alpha, cameraZoom: 2 + alpha)
                let isOne = TileStyleFadeMath.fadeIsOne(mask: mask, overviewFade: uniform)
                let isZero = TileStyleFadeMath.fadeIsZero(mask: mask, overviewFade: uniform)
                XCTAssertFalse(isOne && isZero, "mask \(mask), alpha \(alpha)")
            }
        }
    }
}
