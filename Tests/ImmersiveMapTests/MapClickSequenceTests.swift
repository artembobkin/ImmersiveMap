// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// A click and a double click told apart from the presses the map sees.
final class MapClickSequenceTests: XCTestCase {
    private let spot = CGPoint(x: 100, y: 100)

    private func press(_ sequence: inout MapClickSequence, at point: CGPoint, time: TimeInterval,
                       waitsForDouble: Bool = true) -> MapClickSequence.Outcome {
        sequence.press(at: point, time: time, interval: 0.5, reach: 12, waitsForDouble: waitsForDouble)
    }

    func testAPressIsAClickAtOnceWhenADoubleClickMeansNothing() {
        var sequence = MapClickSequence()
        XCTAssertEqual(press(&sequence, at: spot, time: 1, waitsForDouble: false), .click)
        XCTAssertEqual(press(&sequence, at: spot, time: 1.1, waitsForDouble: false), .click,
                       "Two quick presses are two clicks")
    }

    func testTwoPressesNearEachOtherAreADoubleClick() {
        var sequence = MapClickSequence()
        XCTAssertEqual(press(&sequence, at: spot, time: 1), .pending(flushed: nil))
        XCTAssertEqual(press(&sequence, at: CGPoint(x: 108, y: 94), time: 1.3), .doubleClick,
                       "The second press need not land on the first")
        XCTAssertNil(sequence.expire(pressedAt: 1), "The first press is no click of its own")
        XCTAssertEqual(press(&sequence, at: spot, time: 1.4), .pending(flushed: nil), "A third press starts anew")
    }

    func testAPressLeftAloneIsAClickAfterTheInterval() {
        var sequence = MapClickSequence()
        XCTAssertEqual(press(&sequence, at: spot, time: 1), .pending(flushed: nil))
        XCTAssertEqual(sequence.expire(pressedAt: 1), spot)
        XCTAssertNil(sequence.expire(pressedAt: 1), "Once")
    }

    func testAPressTooLateOrTooFarIsAClickOfItsOwn() {
        var sequence = MapClickSequence()
        _ = press(&sequence, at: spot, time: 1)
        let far = CGPoint(x: 160, y: 100)
        XCTAssertEqual(press(&sequence, at: far, time: 1.2), .pending(flushed: spot),
                       "The first is a click now, the second waits in its turn")
        XCTAssertNil(sequence.expire(pressedAt: 1))
        XCTAssertEqual(sequence.expire(pressedAt: 1.2), far)

        _ = press(&sequence, at: spot, time: 5)
        XCTAssertEqual(press(&sequence, at: spot, time: 5.9), .pending(flushed: spot), "Too late to pair")
    }
}
