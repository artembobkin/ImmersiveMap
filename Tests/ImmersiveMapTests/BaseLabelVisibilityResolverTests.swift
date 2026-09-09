// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The per-label rules of the frame path: which labels reserve collision
/// space and which want to be shown, written in place.
final class BaseLabelVisibilityResolverTests: XCTestCase {
    private func input(key: UInt64 = 1, duplicate: UInt8 = 0, retained: UInt8 = 0, valid: Bool = true, minZoom: Float = 0) -> BaseLabelPresentationInput {
        BaseLabelPresentationInput(labelKey: key, duplicate: duplicate, isRetained: retained, isValid: valid, minCameraZoom: minZoom)
    }

    func testTargetVisibilityRequiresHorizonAndCollisionAndZoom() {
        let inputs = [input(key: 1), input(key: 2), input(key: 3), input(key: 4, minZoom: 15)]
        var target: [Bool] = []
        BaseLabelVisibilityResolver.targetVisibility(inputs: inputs,
                                                     collisionVisible: [true, true, false, true],
                                                     horizonVisibility: [true, false, true, true],
                                                     cameraZoom: 14,
                                                     into: &target)
        XCTAssertEqual(target, [true, false, false, false],
                       "Behind the horizon, lost the collision, below its zoom: each hides")
    }

    func testTargetVisibilityHidesDuplicatesRetainedAndEmptySlots() {
        let inputs = [input(key: 1, duplicate: 1), input(key: 2, retained: 1), input(key: 0, valid: false), input(key: 3)]
        var target = [Bool](repeating: true, count: 4)
        BaseLabelVisibilityResolver.targetVisibility(inputs: inputs,
                                                     collisionVisible: [true, true, true, true],
                                                     horizonVisibility: [true, true, true, true],
                                                     cameraZoom: 14,
                                                     into: &target)
        XCTAssertEqual(target, [false, false, false, true])
    }

    func testTargetVisibilityResizesTheOutputToTheInputs() {
        var target: [Bool] = [true, true, true, true, true, true]
        BaseLabelVisibilityResolver.targetVisibility(inputs: [input()],
                                                     collisionVisible: [true],
                                                     horizonVisibility: [true],
                                                     cameraZoom: 14,
                                                     into: &target)
        XCTAssertEqual(target, [true])
        BaseLabelVisibilityResolver.targetVisibility(inputs: [input(), input(key: 2)],
                                                     collisionVisible: [true],
                                                     horizonVisibility: [true, true],
                                                     cameraZoom: 14,
                                                     into: &target)
        XCTAssertEqual(target, [true, false], "A missing collision entry counts as hidden")
    }

    func testReservationRemainsDuringFadeOutBehindHorizon() {
        XCTAssertTrue(BaseLabelVisibilityResolver.reservesSpace(candidateEnabled: true, screenVisible: true, horizonVisible: false,
                                                                currentAlpha: 0.4, minCameraZoom: 0, cameraZoom: 14),
                      "Still fading out behind the horizon: keeps its space so neighbours do not jump")
        XCTAssertFalse(BaseLabelVisibilityResolver.reservesSpace(candidateEnabled: true, screenVisible: true, horizonVisible: false,
                                                                 currentAlpha: 0, minCameraZoom: 0, cameraZoom: 14),
                       "Fully transparent behind the horizon: reserves nothing")
    }

    func testReservationNeedsADrawablePointAndAnEnabledCandidate() {
        XCTAssertFalse(BaseLabelVisibilityResolver.reservesSpace(candidateEnabled: true, screenVisible: false, horizonVisible: true,
                                                                 currentAlpha: 1, minCameraZoom: 0, cameraZoom: 14))
        XCTAssertFalse(BaseLabelVisibilityResolver.reservesSpace(candidateEnabled: false, screenVisible: true, horizonVisible: true,
                                                                 currentAlpha: 1, minCameraZoom: 0, cameraZoom: 14))
    }

    func testReservationIsSuppressedBelowMinCameraZoomWhileInvisible() {
        XCTAssertFalse(BaseLabelVisibilityResolver.reservesSpace(candidateEnabled: true, screenVisible: true, horizonVisible: true,
                                                                 currentAlpha: 0, minCameraZoom: 15, cameraZoom: 14),
                       "A zoom-hidden POI must not displace visible labels")
        XCTAssertTrue(BaseLabelVisibilityResolver.reservesSpace(candidateEnabled: true, screenVisible: true, horizonVisible: true,
                                                                currentAlpha: 0.5, minCameraZoom: 15, cameraZoom: 14),
                      "but one still fading out after crossing the zoom keeps its spot")
        XCTAssertTrue(BaseLabelVisibilityResolver.reservesSpace(candidateEnabled: true, screenVisible: true, horizonVisible: true,
                                                                currentAlpha: 0, minCameraZoom: 15, cameraZoom: 16))
    }
}
