// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The one-thumb tilt zone works in an inverted control value: 0 is the pitch
/// ceiling and the largest value is the floor, so a configured `minimumPitch`
/// shortens the reachable span instead of leaving a dead stretch of the zone.
final class PitchControlMathTests: XCTestCase {
    func testControlValueSpansCeilingDownToFloor() {
        XCTAssertEqual(PitchControlMath.actualPitch(forControlValue: 0, minimumPitch: 0.3, maximumPitch: 1.2),
                       1.2,
                       accuracy: 0.0001)
        XCTAssertEqual(PitchControlMath.actualPitch(forControlValue: 10, minimumPitch: 0.3, maximumPitch: 1.2),
                       0.3,
                       accuracy: 0.0001)
    }

    func testControlValueRoundTripsThePitch() {
        let value = PitchControlMath.controlValue(forActualPitch: 0.7, minimumPitch: 0.3, maximumPitch: 1.2)

        XCTAssertEqual(PitchControlMath.actualPitch(forControlValue: value, minimumPitch: 0.3, maximumPitch: 1.2),
                       0.7,
                       accuracy: 0.0001)
    }

    func testDragDeltaScalesWithTheReachableSpan() {
        // A full-height drag traverses exactly the reachable span, so the zone
        // keeps its feel whatever the configured range is.
        let delta = PitchControlMath.controlValueDelta(forVerticalTranslation: -100,
                                                       interactionHeight: 100,
                                                       minimumPitch: 0.3,
                                                       maximumPitch: 1.2)

        XCTAssertEqual(delta, 0.9, accuracy: 0.0001)
    }

    func testCollapsedRangeProducesNoMotion() {
        let delta = PitchControlMath.controlValueDelta(forVerticalTranslation: -100,
                                                       interactionHeight: 100,
                                                       minimumPitch: 1.2,
                                                       maximumPitch: 1.2)

        XCTAssertEqual(delta, 0)
    }
}
