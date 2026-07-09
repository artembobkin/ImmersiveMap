// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class BaseLabelVisibilityResolverTests: XCTestCase {
    func testTargetVisibilityRequiresHorizonVisibility() {
        let inputs = [
            BaseLabelPresentationInput(labelKey: 1, duplicate: 0, isRetained: 0, isValid: true),
            BaseLabelPresentationInput(labelKey: 2, duplicate: 0, isRetained: 0, isValid: true)
        ]
        let collisionFlags: [UInt32] = [0, 0]
        let horizonVisibility = [true, false]

        let result = BaseLabelVisibilityResolver.targetVisibility(inputs: inputs,
                                                                  collisionFlags: collisionFlags,
                                                                  horizonVisibility: horizonVisibility)

        XCTAssertEqual(result, [true, false])
    }

    func testTargetVisibilityStillHonorsCollisionHidden() {
        let inputs = [
            BaseLabelPresentationInput(labelKey: 1, duplicate: 0, isRetained: 0, isValid: true),
            BaseLabelPresentationInput(labelKey: 2, duplicate: 0, isRetained: 0, isValid: true)
        ]
        let collisionFlags: [UInt32] = [0, 1]
        let horizonVisibility = [true, true]

        let result = BaseLabelVisibilityResolver.targetVisibility(inputs: inputs,
                                                                  collisionFlags: collisionFlags,
                                                                  horizonVisibility: horizonVisibility)

        XCTAssertEqual(result, [true, false])
    }

    func testTargetVisibilityAllowsHorizonVisibleLabelWhenCollisionVisibilityIsStale() {
        let inputs = [
            BaseLabelPresentationInput(labelKey: 1, duplicate: 0, isRetained: 0, isValid: true)
        ]

        let result = BaseLabelVisibilityResolver.targetVisibility(inputs: inputs,
                                                                  collisionFlags: [1],
                                                                  horizonVisibility: [true],
                                                                  collisionVisibilityIsFresh: false)

        XCTAssertEqual(result, [true])
    }

    func testTargetVisibilityRejectsUnknownCollisionVisibility() {
        let inputs = [
            BaseLabelPresentationInput(labelKey: 1, duplicate: 0, isRetained: 0, isValid: true)
        ]

        let result = BaseLabelVisibilityResolver.targetVisibility(inputs: inputs,
                                                                  collisionVisibility: [.unknown],
                                                                  horizonVisibility: [true])

        XCTAssertEqual(result, [false])
    }

    func testTargetVisibilityRejectsHiddenCollisionVisibility() {
        let inputs = [
            BaseLabelPresentationInput(labelKey: 1, duplicate: 0, isRetained: 0, isValid: true)
        ]

        let result = BaseLabelVisibilityResolver.targetVisibility(inputs: inputs,
                                                                  collisionVisibility: [.hidden],
                                                                  horizonVisibility: [true])

        XCTAssertEqual(result, [false])
    }

    func testCollisionCandidateRemainsEnabledDuringFadeOutBehindHorizon() {
        let baseCandidates = [
            ScreenCollisionCandidate(position: .zero,
                                     halfSize: SIMD2<Float>(10, 4),
                                     priority: 1,
                                     secondaryPriority: 2,
                                     isEnabled: true)
        ]
        let screenPoints = [
            ScreenPointOutput(position: SIMD2<Float>(40, 50),
                              depth: 0.5,
                              visible: 1,
                              visibilityAlpha: 1)
        ]
        let result = BaseLabelVisibilityResolver.collisionCandidates(baseCandidates: baseCandidates,
                                                                    screenPoints: screenPoints,
                                                                    horizonVisibility: [false],
                                                                    currentAlphas: [0.4])

        XCTAssertEqual(result[0].position, SIMD2<Float>(40, 50))
        XCTAssertTrue(result[0].isEnabled)
    }

    func testCollisionCandidateIsDisabledBehindHorizonWhenFullyTransparent() {
        let baseCandidates = [
            ScreenCollisionCandidate(position: .zero,
                                     halfSize: SIMD2<Float>(10, 4),
                                     priority: 1,
                                     secondaryPriority: 2,
                                     isEnabled: true)
        ]
        let screenPoints = [
            ScreenPointOutput(position: SIMD2<Float>(40, 50),
                              depth: 0.5,
                              visible: 1,
                              visibilityAlpha: 1)
        ]
        let result = BaseLabelVisibilityResolver.collisionCandidates(baseCandidates: baseCandidates,
                                                                    screenPoints: screenPoints,
                                                                    horizonVisibility: [false],
                                                                    currentAlphas: [0])

        XCTAssertFalse(result[0].isEnabled)
    }

    func testCollisionCandidateIsDisabledWhenScreenPointIsNotDrawable() {
        let baseCandidates = [
            ScreenCollisionCandidate(position: .zero,
                                     halfSize: SIMD2<Float>(10, 4),
                                     priority: 1,
                                     secondaryPriority: 2,
                                     isEnabled: true)
        ]
        let screenPoints = [
            ScreenPointOutput(position: .zero,
                              depth: 0,
                              visible: 0,
                              visibilityAlpha: 0)
        ]
        let result = BaseLabelVisibilityResolver.collisionCandidates(baseCandidates: baseCandidates,
                                                                    screenPoints: screenPoints,
                                                                    horizonVisibility: [true],
                                                                    currentAlphas: [1])

        XCTAssertFalse(result[0].isEnabled)
    }

    func testCollisionCandidateIsDisabledWithoutMatchingScreenPoint() {
        let baseCandidates = [
            ScreenCollisionCandidate(position: .zero,
                                     halfSize: SIMD2<Float>(10, 4),
                                     priority: 1,
                                     secondaryPriority: 2,
                                     isEnabled: true)
        ]

        let result = BaseLabelVisibilityResolver.collisionCandidates(baseCandidates: baseCandidates,
                                                                    screenPoints: [],
                                                                    horizonVisibility: [true],
                                                                    currentAlphas: [1])

        XCTAssertFalse(result[0].isEnabled)
    }

    func testHorizonReservationSignatureChangesWhenHiddenAlphaCrossesThreshold() {
        let active = BaseLabelVisibilityResolver.horizonReservationSignature(horizonVisibility: [false, true],
                                                                             currentAlphas: [0.4, 0.9])
        let inactive = BaseLabelVisibilityResolver.horizonReservationSignature(horizonVisibility: [false, true],
                                                                               currentAlphas: [0, 0.9])

        XCTAssertEqual(active, [0])
        XCTAssertTrue(inactive.isEmpty)
    }

    func testHorizonReservationSignatureIgnoresVisibleHorizonLabels() {
        let result = BaseLabelVisibilityResolver.horizonReservationSignature(horizonVisibility: [true, true],
                                                                             currentAlphas: [0.4, 0.8])

        XCTAssertTrue(result.isEmpty)
    }
}
