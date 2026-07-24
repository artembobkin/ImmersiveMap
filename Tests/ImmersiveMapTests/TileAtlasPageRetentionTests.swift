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
        // Страницы выгружены: следующие flat-кадры без страниц ничего не выгружают.
        XCTAssertFalse(retention.shouldReleasePages(isSpherical: false, hasPages: false, time: delay * 3))
        // Если страницы почему-то живы (выгрузка не состоялась), отсчёт начинается заново.
        XCTAssertFalse(retention.shouldReleasePages(isSpherical: false, hasPages: true, time: delay * 4))
        XCTAssertTrue(retention.shouldReleasePages(isSpherical: false, hasPages: true, time: delay * 5))
    }

    func testReturningToGlobeResetsCountdown() {
        var retention = TileAtlasPageRetention()
        let delay = TileAtlasPageRetention.releaseDelay

        XCTAssertFalse(retention.shouldReleasePages(isSpherical: true, hasPages: true, time: 0))
        XCTAssertFalse(retention.shouldReleasePages(isSpherical: false, hasPages: true, time: delay * 0.9))
        XCTAssertFalse(retention.shouldReleasePages(isSpherical: true, hasPages: true, time: delay))
        // Осцилляция вокруг границы перехода: свежий глобусный кадр обнуляет отсчёт.
        XCTAssertFalse(retention.shouldReleasePages(isSpherical: false, hasPages: true, time: delay * 1.5))
        XCTAssertTrue(retention.shouldReleasePages(isSpherical: false, hasPages: true, time: delay * 2))
    }

    func testPagesWithoutSeenSphericalFrameStartCountdownFromFirstFlatFrame() {
        var retention = TileAtlasPageRetention()
        let delay = TileAtlasPageRetention.releaseDelay

        // Страницы пережили пересоздание состояния: не выгружаем мгновенно,
        // отсчёт стартует с первого наблюдаемого flat-кадра.
        XCTAssertFalse(retention.shouldReleasePages(isSpherical: false, hasPages: true, time: 1000))
        XCTAssertFalse(retention.shouldReleasePages(isSpherical: false, hasPages: true, time: 1000 + delay * 0.5))
        XCTAssertTrue(retention.shouldReleasePages(isSpherical: false, hasPages: true, time: 1000 + delay))
    }
}
