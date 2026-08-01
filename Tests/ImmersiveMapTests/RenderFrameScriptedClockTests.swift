// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class RenderFrameScriptedClockTests: XCTestCase {
    func testFirstTickHasZeroDelta() {
        let clock = RenderFrameScriptedClock()
        clock.setTime(5)

        let tick = clock.nextFrameTick()

        XCTAssertEqual(tick.index, 1)
        XCTAssertEqual(tick.time, 5)
        XCTAssertEqual(tick.deltaTime, 0)
    }

    func testHeldTimeYieldsZeroDeltaWithGrowingIndex() {
        let clock = RenderFrameScriptedClock()
        clock.setTime(1)
        _ = clock.nextFrameTick()

        let second = clock.nextFrameTick()
        let third = clock.nextFrameTick()

        XCTAssertEqual(second.index, 2)
        XCTAssertEqual(second.deltaTime, 0)
        XCTAssertEqual(second.time, 1)
        XCTAssertEqual(third.index, 3)
        XCTAssertEqual(third.deltaTime, 0)
    }

    func testAdvancingTimeYieldsExactDeltas() {
        let clock = RenderFrameScriptedClock()
        let step: TimeInterval = 1.0 / 60.0
        clock.setTime(0)
        _ = clock.nextFrameTick()

        clock.setTime(step)
        let second = clock.nextFrameTick()
        clock.setTime(step * 2)
        let third = clock.nextFrameTick()

        XCTAssertEqual(second.deltaTime, step, accuracy: 1e-12)
        XCTAssertEqual(second.time, step, accuracy: 1e-12)
        XCTAssertEqual(third.deltaTime, step, accuracy: 1e-12)
        XCTAssertEqual(third.time, step * 2, accuracy: 1e-12)
    }

    func testDateIsFixedUntilChanged() {
        let initialDate = Date(timeIntervalSince1970: 1_000)
        let clock = RenderFrameScriptedClock(date: initialDate)

        XCTAssertEqual(clock.currentDate(), initialDate)
        _ = clock.nextFrameTick()
        XCTAssertEqual(clock.currentDate(), initialDate)

        let laterDate = Date(timeIntervalSince1970: 2_000)
        clock.setDate(laterDate)
        XCTAssertEqual(clock.currentDate(), laterDate)
    }

    func testWallClockFirstTickHasZeroDeltaAndGrowingIndex() {
        let clock = RenderFrameWallClock()

        let first = clock.nextFrameTick()
        let second = clock.nextFrameTick()

        XCTAssertEqual(first.index, 1)
        XCTAssertEqual(first.deltaTime, 0)
        XCTAssertEqual(second.index, 2)
        XCTAssertGreaterThanOrEqual(second.deltaTime, 0)
    }
}
