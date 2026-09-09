// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The index-aligned fade state: a target takes effect from the next frame,
/// alphas follow the keys across a topology change, and dropped labels
/// leave no state behind.
final class BaseLabelFadeStateTests: XCTestCase {
    func testTargetVisibilityFalseStartsFadeOutOnFollowingFrame() {
        let state = BaseLabelFadeState()
        state.rebind(keys: [1], time: 0)

        state.advance(targetVisibility: [true], time: 0, fadeInSeconds: 0, fadeOutSeconds: 1)
        XCTAssertEqual(state.currentAlphas[0], 0, "The first frame stores the target; the alpha moves from the next one")
        state.advance(targetVisibility: [true], time: 0.1, fadeInSeconds: 0, fadeOutSeconds: 1)
        XCTAssertEqual(state.currentAlphas[0], 1)

        let stillVisible = state.advance(targetVisibility: [false], time: 0.35, fadeInSeconds: 0, fadeOutSeconds: 1)
        XCTAssertEqual(state.currentAlphas[0], 1, "The frame that flips the target still shows the label")
        XCTAssertTrue(stillVisible, "and reports the fade it just started")

        let fadingOut = state.advance(targetVisibility: [false], time: 0.60, fadeInSeconds: 0, fadeOutSeconds: 1)
        XCTAssertEqual(state.currentAlphas[0], 0.75, accuracy: 1e-6)
        XCTAssertTrue(fadingOut)

        let done = state.advance(targetVisibility: [false], time: 2, fadeInSeconds: 0, fadeOutSeconds: 1)
        XCTAssertEqual(state.currentAlphas[0], 0)
        XCTAssertFalse(done)
    }

    func testFadeInFollowsItsOwnDuration() {
        let state = BaseLabelFadeState()
        state.rebind(keys: [7], time: 0)
        state.advance(targetVisibility: [true], time: 0, fadeInSeconds: 0.5, fadeOutSeconds: 1)
        state.advance(targetVisibility: [true], time: 0.25, fadeInSeconds: 0.5, fadeOutSeconds: 1)
        XCTAssertEqual(state.currentAlphas[0], 0.5, accuracy: 1e-6)
        state.advance(targetVisibility: [true], time: 1, fadeInSeconds: 0.5, fadeOutSeconds: 1)
        XCTAssertEqual(state.currentAlphas[0], 1)
    }

    func testRebindCarriesAlphaByKeyAndDropsTheRest() {
        let state = BaseLabelFadeState()
        state.rebind(keys: [1, 2, 3], time: 0)
        state.advance(targetVisibility: [true, true, true], time: 0, fadeInSeconds: 1, fadeOutSeconds: 1)
        state.advance(targetVisibility: [true, true, true], time: 0.5, fadeInSeconds: 1, fadeOutSeconds: 1)
        XCTAssertEqual(state.currentAlphas, [0.5, 0.5, 0.5])

        // Tile churn reorders the set: 3 leaves, 4 arrives, 1 and 2 swap.
        state.rebind(keys: [2, 4, 1], time: 0.5)
        XCTAssertEqual(state.count, 3)
        XCTAssertEqual(state.currentAlphas, [0.5, 0, 0.5], "Alphas follow their keys; the newcomer starts invisible")

        state.advance(targetVisibility: [true, true, true], time: 1.0, fadeInSeconds: 1, fadeOutSeconds: 1)
        XCTAssertEqual(state.currentAlphas, [1, 0, 1], "The carried labels keep their stored target and finish the fade")
    }

    func testTheEmptyKeyCarriesNoState() {
        let state = BaseLabelFadeState()
        state.rebind(keys: [0, 5], time: 0)
        state.advance(targetVisibility: [true, true], time: 0, fadeInSeconds: 0, fadeOutSeconds: 0)
        state.advance(targetVisibility: [true, true], time: 1, fadeInSeconds: 0, fadeOutSeconds: 0)
        state.rebind(keys: [5, 0], time: 1)
        XCTAssertEqual(state.currentAlphas, [1, 0], "Key 0 (an empty slot) never inherits an alpha")
    }

    func testRebindCarriesTheShownCopyOfADuplicatedKey() {
        // Key 9 sits at two indices: a hidden copy (a coarse tile's duplicate)
        // before the shown one in the arena, as a tilted camera produces.
        let state = BaseLabelFadeState()
        state.rebind(keys: [9, 2, 9], time: 0)
        state.advance(targetVisibility: [false, true, true], time: 0, fadeInSeconds: 0, fadeOutSeconds: 0)
        state.advance(targetVisibility: [false, true, true], time: 1, fadeInSeconds: 0, fadeOutSeconds: 0)
        XCTAssertEqual(state.currentAlphas, [0, 1, 1])

        // Another tile arrives; the copies keep their order.
        state.rebind(keys: [9, 2, 9, 4], time: 1)
        XCTAssertEqual(state.currentAlphas, [1, 1, 1, 0],
                       "The shown copy's alpha carries over, not the hidden copy's zero")

        state.advance(targetVisibility: [false, true, true, true], time: 1, fadeInSeconds: 1, fadeOutSeconds: 1)
        state.advance(targetVisibility: [false, true, true, true], time: 1.5, fadeInSeconds: 1, fadeOutSeconds: 1)
        XCTAssertEqual(state.currentAlphas, [0.5, 1, 1, 0.5],
                       "The hidden copy fades out from the carried alpha; the shown one stays put")
    }

    func testRebindWithTheSameKeysKeepsEverything() {
        let state = BaseLabelFadeState()
        state.rebind(keys: [1, 2], time: 0)
        state.advance(targetVisibility: [true, false], time: 0, fadeInSeconds: 0, fadeOutSeconds: 0)
        state.advance(targetVisibility: [true, false], time: 1, fadeInSeconds: 0, fadeOutSeconds: 0)
        state.rebind(keys: [1, 2], time: 5)
        XCTAssertEqual(state.currentAlphas, [1, 0])
    }
}
