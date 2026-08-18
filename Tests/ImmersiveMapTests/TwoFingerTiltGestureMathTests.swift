// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The two-finger tilt shares its touches with the pinch and rotation
/// recognizers, so its math has to commit to tilting only for the drag that
/// means it: fingers side by side, moving together mostly vertically.
final class TwoFingerTiltGestureMathTests: XCTestCase {
    // MARK: - Touch layout

    func testFingersSideBySideMayTilt() {
        XCTAssertTrue(TwoFingerTiltGestureMath.touchLayoutAllowsTilt(CGPoint(x: 100, y: 300),
                                                                     CGPoint(x: 220, y: 310)))
    }

    func testFingersStackedVerticallyNeverTilt() {
        XCTAssertFalse(TwoFingerTiltGestureMath.touchLayoutAllowsTilt(CGPoint(x: 160, y: 200),
                                                                      CGPoint(x: 170, y: 420)))
    }

    func testDiagonalFingerLayoutStillTilts() {
        XCTAssertTrue(TwoFingerTiltGestureMath.touchLayoutAllowsTilt(CGPoint(x: 100, y: 100),
                                                                     CGPoint(x: 200, y: 200)))
    }

    // MARK: - Intent

    func testShortMovementStaysUndecided() {
        XCTAssertEqual(TwoFingerTiltGestureMath.intent(ofTranslation: CGPoint(x: 1, y: -3)),
                       .undecided)
    }

    func testMostlyVerticalMovementIsATilt() {
        XCTAssertEqual(TwoFingerTiltGestureMath.intent(ofTranslation: CGPoint(x: 2, y: -14)),
                       .tilt)
        XCTAssertEqual(TwoFingerTiltGestureMath.intent(ofTranslation: CGPoint(x: -1, y: 12)),
                       .tilt)
    }

    func testMostlyHorizontalMovementIsLeftToOtherGestures() {
        XCTAssertEqual(TwoFingerTiltGestureMath.intent(ofTranslation: CGPoint(x: 15, y: 4)),
                       .other)
    }

    func testPurelyDiagonalMovementIsNotATilt() {
        XCTAssertEqual(TwoFingerTiltGestureMath.intent(ofTranslation: CGPoint(x: 10, y: -10)),
                       .other)
    }

    // MARK: - Pitch delta

    func testDraggingDownTiltsFurther() {
        let delta = TwoFingerTiltGestureMath.pitchDelta(forVerticalTranslation: 100,
                                                        viewHeight: 800,
                                                        maximumPitch: 1.2,
                                                        sensitivity: 1.0)

        XCTAssertEqual(delta, 0.15, accuracy: 0.0001)
    }

    func testDraggingUpLevelsOff() {
        let delta = TwoFingerTiltGestureMath.pitchDelta(forVerticalTranslation: -200,
                                                        viewHeight: 800,
                                                        maximumPitch: 1.2,
                                                        sensitivity: 1.0)

        XCTAssertEqual(delta, -0.3, accuracy: 0.0001)
    }

    func testFullHeightDragSweepsTheFullCeilingAtUnitSensitivity() {
        let delta = TwoFingerTiltGestureMath.pitchDelta(forVerticalTranslation: 800,
                                                        viewHeight: 800,
                                                        maximumPitch: 1.2,
                                                        sensitivity: 1.0)

        XCTAssertEqual(delta, 1.2, accuracy: 0.0001)
    }

    func testSensitivityMultipliesTheDelta() {
        let delta = TwoFingerTiltGestureMath.pitchDelta(forVerticalTranslation: 100,
                                                        viewHeight: 800,
                                                        maximumPitch: 1.2,
                                                        sensitivity: 2.0)

        XCTAssertEqual(delta, 0.3, accuracy: 0.0001)
    }

    func testNegativeSensitivityInvertsTheDirection() {
        let delta = TwoFingerTiltGestureMath.pitchDelta(forVerticalTranslation: -100,
                                                        viewHeight: 800,
                                                        maximumPitch: 1.2,
                                                        sensitivity: -2.0)

        XCTAssertEqual(delta, 0.3, accuracy: 0.0001)
    }

    func testDefaultSettingsTiltAtDoubleSpeed() {
        XCTAssertEqual(ImmersiveMapSettings.default.camera.tiltGestureSensitivity,
                       2.0,
                       accuracy: 0.0001)
    }

    func testZeroHeightViewProducesNoDelta() {
        XCTAssertEqual(TwoFingerTiltGestureMath.pitchDelta(forVerticalTranslation: -100,
                                                           viewHeight: 0,
                                                           maximumPitch: 1.2,
                                                           sensitivity: 2.0),
                       0)
    }
}
