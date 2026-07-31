// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class TileAtlasPageRetentionTests: XCTestCase {
    func testSphericalFramesNeverRelease() {
        var retention = TileAtlasPageRetention()

        XCTAssertFalse(retention.shouldReleasePages(isSpherical: true, hasPages: true, time: 0))
        XCTAssertFalse(retention.shouldReleasePages(isSpherical: true, hasPages: true, time: 100))
    }

    func testFlatFramesKeepPagesUntilDelayElapses() {
        var retention = TileAtlasPageRetention()
        let delay = TileAtlasPageRetention.releaseDelay

        XCTAssertFalse(retention.shouldReleasePages(isSpherical: true, hasPages: true, time: 10))
        XCTAssertFalse(retention.shouldReleasePages(isSpherical: false, hasPages: true, time: 10 + delay * 0.5))
        XCTAssertFalse(retention.shouldReleasePages(isSpherical: false, hasPages: true, time: 10 + delay * 0.99))
        XCTAssertTrue(retention.shouldReleasePages(isSpherical: false, hasPages: true, time: 10 + delay))
    }

    func testReleaseFiresOnceAndCountdownRestartsFromNextFlatFrame() {
        var retention = TileAtlasPageRetention()
        let delay = TileAtlasPageRetention.releaseDelay

        XCTAssertFalse(retention.shouldReleasePages(isSpherical: true, hasPages: true, time: 0))
        XCTAssertTrue(retention.shouldReleasePages(isSpherical: false, hasPages: true, time: delay))
        // Pages are released: subsequent flat frames without pages release nothing.
        XCTAssertFalse(retention.shouldReleasePages(isSpherical: false, hasPages: false, time: delay * 3))
        // If the pages are somehow still alive (the release did not happen), the countdown restarts.
        XCTAssertFalse(retention.shouldReleasePages(isSpherical: false, hasPages: true, time: delay * 4))
        XCTAssertTrue(retention.shouldReleasePages(isSpherical: false, hasPages: true, time: delay * 5))
    }

    func testReturningToGlobeResetsCountdown() {
        var retention = TileAtlasPageRetention()
        let delay = TileAtlasPageRetention.releaseDelay

        XCTAssertFalse(retention.shouldReleasePages(isSpherical: true, hasPages: true, time: 0))
        XCTAssertFalse(retention.shouldReleasePages(isSpherical: false, hasPages: true, time: delay * 0.9))
        XCTAssertFalse(retention.shouldReleasePages(isSpherical: true, hasPages: true, time: delay))
        // Oscillation around the transition boundary: a fresh spherical frame resets the countdown.
        XCTAssertFalse(retention.shouldReleasePages(isSpherical: false, hasPages: true, time: delay * 1.5))
        XCTAssertTrue(retention.shouldReleasePages(isSpherical: false, hasPages: true, time: delay * 2))
    }

    func testPagesWithoutSeenSphericalFrameStartCountdownFromFirstFlatFrame() {
        var retention = TileAtlasPageRetention()
        let delay = TileAtlasPageRetention.releaseDelay

        // Pages survived a state recreation: do not release instantly, the
        // countdown starts from the first observed flat frame.
        XCTAssertFalse(retention.shouldReleasePages(isSpherical: false, hasPages: true, time: 1000))
        XCTAssertFalse(retention.shouldReleasePages(isSpherical: false, hasPages: true, time: 1000 + delay * 0.5))
        XCTAssertTrue(retention.shouldReleasePages(isSpherical: false, hasPages: true, time: 1000 + delay))
    }
}
