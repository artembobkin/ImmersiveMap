// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class BaseLabelPresentationStateStoreTests: XCTestCase {
    func testTargetVisibilityFalseStartsFadeOutOnFollowingFrame() {
        let store = BaseLabelPresentationStateStore()
        let input = BaseLabelPresentationInput(labelKey: 1, duplicate: 0, isRetained: 0, isValid: true, minCameraZoom: 0)

        _ = store.resolveAlphas(inputs: [input],
                                targetVisibility: [true],
                                time: 0,
                                frameIndex: 1,
                                fadeInSeconds: 0,
                                fadeOutSeconds: 1)
        let visibleResolution = store.resolveAlphas(inputs: [input],
                                                    targetVisibility: [true],
                                                    time: 0.1,
                                                    frameIndex: 2,
                                                    fadeInSeconds: 0,
                                                    fadeOutSeconds: 1)
        XCTAssertEqual(visibleResolution.fadeAlphas[0], 1)

        let targetChangedResolution = store.resolveAlphas(inputs: [input],
                                                          targetVisibility: [false],
                                                          time: 0.35,
                                                          frameIndex: 3,
                                                          fadeInSeconds: 0,
                                                          fadeOutSeconds: 1)
        XCTAssertEqual(targetChangedResolution.fadeAlphas[0], 1)

        let fadeOutResolution = store.resolveAlphas(inputs: [input],
                                                    targetVisibility: [false],
                                                    time: 0.60,
                                                    frameIndex: 4,
                                                    fadeInSeconds: 0,
                                                    fadeOutSeconds: 1)
        XCTAssertEqual(fadeOutResolution.fadeAlphas[0], 0.75)
        XCTAssertTrue(fadeOutResolution.hasActiveAnimations)
    }

    func testCurrentAlphaSnapshotAdvancesStoredAlphaWithoutChangingTargets() {
        let timestampGuard = makeStoreAfterFadeOutTargetChange()

        let timestampSnapshot = timestampGuard.store.currentAlphas(inputs: [timestampGuard.input],
                                                                   time: 0.5,
                                                                   fadeInSeconds: 0,
                                                                   fadeOutSeconds: 1)
        XCTAssertEqual(timestampSnapshot, [0.75])

        let timestampResolution = timestampGuard.store.resolveAlphas(inputs: [timestampGuard.input],
                                                                     targetVisibility: [false],
                                                                     time: 0.75,
                                                                     frameIndex: 4,
                                                                     fadeInSeconds: 0,
                                                                     fadeOutSeconds: 1)
        XCTAssertEqual(timestampResolution.fadeAlphas[0], 0.5)

        let currentAlphaGuard = makeStoreAfterFadeOutTargetChange()

        let currentAlphaSnapshot = currentAlphaGuard.store.currentAlphas(inputs: [currentAlphaGuard.input],
                                                                         time: 0.5,
                                                                         fadeInSeconds: 0,
                                                                         fadeOutSeconds: 1)
        XCTAssertEqual(currentAlphaSnapshot, [0.75])

        let currentAlphaResolution = currentAlphaGuard.store.resolveAlphas(inputs: [currentAlphaGuard.input],
                                                                           targetVisibility: [false],
                                                                           time: 0.25,
                                                                           frameIndex: 4,
                                                                           fadeInSeconds: 0,
                                                                           fadeOutSeconds: 1)
        XCTAssertEqual(currentAlphaResolution.fadeAlphas[0], 1)
    }

    func testCurrentAlphaSnapshotReturnsZeroForDuplicateInvalidAndMissingEntries() {
        let store = BaseLabelPresentationStateStore()
        let validUnseenInput = BaseLabelPresentationInput(labelKey: 1, duplicate: 0, isRetained: 0, isValid: true, minCameraZoom: 0)
        let duplicateEntryInput = BaseLabelPresentationInput(labelKey: 2, duplicate: 0, isRetained: 0, isValid: true, minCameraZoom: 0)
        let duplicateInput = BaseLabelPresentationInput(labelKey: 2, duplicate: 1, isRetained: 0, isValid: true, minCameraZoom: 0)
        let invalidEntryInput = BaseLabelPresentationInput(labelKey: 3, duplicate: 0, isRetained: 0, isValid: true, minCameraZoom: 0)
        let invalidInput = BaseLabelPresentationInput(labelKey: 3, duplicate: 0, isRetained: 0, isValid: false, minCameraZoom: 0)

        _ = store.resolveAlphas(inputs: [duplicateEntryInput, invalidEntryInput],
                                targetVisibility: [true, true],
                                time: 0,
                                frameIndex: 1,
                                fadeInSeconds: 0,
                                fadeOutSeconds: 1)
        _ = store.resolveAlphas(inputs: [duplicateEntryInput, invalidEntryInput],
                                targetVisibility: [true, true],
                                time: 0.1,
                                frameIndex: 2,
                                fadeInSeconds: 0,
                                fadeOutSeconds: 1)

        let snapshot = store.currentAlphas(inputs: [validUnseenInput, duplicateInput, invalidInput],
                                           time: 0.5,
                                           fadeInSeconds: 0,
                                           fadeOutSeconds: 1)

        XCTAssertEqual(snapshot, [0, 0, 0])
    }

    private func makeStoreAfterFadeOutTargetChange() -> (store: BaseLabelPresentationStateStore,
                                                         input: BaseLabelPresentationInput) {
        let store = BaseLabelPresentationStateStore()
        let input = BaseLabelPresentationInput(labelKey: 1, duplicate: 0, isRetained: 0, isValid: true, minCameraZoom: 0)

        _ = store.resolveAlphas(inputs: [input],
                                targetVisibility: [true],
                                time: 0,
                                frameIndex: 1,
                                fadeInSeconds: 0,
                                fadeOutSeconds: 1)
        _ = store.resolveAlphas(inputs: [input],
                                targetVisibility: [true],
                                time: 0.1,
                                frameIndex: 2,
                                fadeInSeconds: 0,
                                fadeOutSeconds: 1)
        _ = store.resolveAlphas(inputs: [input],
                                targetVisibility: [false],
                                time: 0.25,
                                frameIndex: 3,
                                fadeInSeconds: 0,
                                fadeOutSeconds: 1)

        return (store, input)
    }
}
