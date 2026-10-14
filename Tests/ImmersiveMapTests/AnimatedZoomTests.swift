// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The animated zoom follows the camera's zoom over time and snaps when
/// the camera is set outright.
final class AnimatedZoomTests: XCTestCase {
    func testTheFirstFrameTakesTheZoomAtOnce() {
        var zoom = AnimatedZoom()
        XCTAssertEqual(zoom.advance(toward: 14, deltaTime: 1 / 60, halfLife: 0.2), 14)
        XCTAssertFalse(zoom.isSettling)
    }

    func testAJumpClosesHalfTheWayEveryHalfLife() {
        var zoom = AnimatedZoom()
        _ = zoom.advance(toward: 14, deltaTime: 1 / 60, halfLife: 0.2)
        XCTAssertEqual(zoom.advance(toward: 13, deltaTime: 0.2, halfLife: 0.2), 13.5, accuracy: 1e-9)
        XCTAssertTrue(zoom.isSettling)
        XCTAssertEqual(zoom.advance(toward: 13, deltaTime: 0.2, halfLife: 0.2), 13.25, accuracy: 1e-9)
        XCTAssertEqual(zoom.advance(toward: 13, deltaTime: 0.4, halfLife: 0.2), 13.0625, accuracy: 1e-9,
                       "Two half-lives in one frame close three quarters")
    }

    func testItSettlesOnTheZoomAndStopsAsking() {
        var zoom = AnimatedZoom()
        _ = zoom.advance(toward: 14, deltaTime: 1 / 60, halfLife: 0.2)
        var frames = 0
        while zoom.advance(toward: 13, deltaTime: 1 / 60, halfLife: 0.2) != 13, frames < 600 {
            frames += 1
        }
        XCTAssertFalse(zoom.isSettling)
        XCTAssertEqual(zoom.value, 13)
        XCTAssertGreaterThan(frames, 10, "It took its time")
        XCTAssertLessThan(frames, 200, "A level settles within a few seconds")
    }

    func testASnapAndAZeroHalfLifeTakeTheZoomAtOnce() {
        var zoom = AnimatedZoom()
        _ = zoom.advance(toward: 14, deltaTime: 1 / 60, halfLife: 0.2)
        XCTAssertEqual(zoom.advance(toward: 3, deltaTime: 1 / 60, halfLife: 0.2, snap: true), 3)
        XCTAssertFalse(zoom.isSettling)
        XCTAssertEqual(zoom.advance(toward: 15, deltaTime: 1 / 60, halfLife: 0), 15)
        XCTAssertFalse(zoom.isSettling)
    }

    func testAFrameWithoutTimeHoldsStill() {
        var zoom = AnimatedZoom()
        _ = zoom.advance(toward: 14, deltaTime: 1 / 60, halfLife: 0.2)
        XCTAssertEqual(zoom.advance(toward: 13, deltaTime: 0, halfLife: 0.2), 14)
        XCTAssertTrue(zoom.isSettling, "Still on its way")
    }
}
