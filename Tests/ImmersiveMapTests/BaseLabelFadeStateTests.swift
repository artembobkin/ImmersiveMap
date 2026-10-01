// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The index-aligned fade state: a target takes effect from the next frame,
/// alphas follow their tile's run across a topology change, and dropped
/// labels leave no state behind.
final class BaseLabelFadeStateTests: XCTestCase {
    private func set(_ count: Int, moves: [LabelBlockMove] = []) -> LabelWorkingSetChange {
        LabelWorkingSetChange(count: count, moves: moves)
    }

    func testTargetVisibilityFalseStartsFadeOutOnFollowingFrame() {
        let state = BaseLabelFadeState()
        state.rebind(change: set(1), time: 0)

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
        state.rebind(change: set(1), time: 0)
        state.advance(targetVisibility: [true], time: 0, fadeInSeconds: 0.5, fadeOutSeconds: 1)
        state.advance(targetVisibility: [true], time: 0.25, fadeInSeconds: 0.5, fadeOutSeconds: 1)
        XCTAssertEqual(state.currentAlphas[0], 0.5, accuracy: 1e-6)
        state.advance(targetVisibility: [true], time: 1, fadeInSeconds: 0.5, fadeOutSeconds: 1)
        XCTAssertEqual(state.currentAlphas[0], 1)
    }

    /// Three tiles of one label each. A pan drops the third, brings a new
    /// one in second place and swaps the first two: the survivors' runs
    /// move, the newcomer starts invisible.
    func testRebindCarriesTheSurvivingRunsAndDropsTheRest() {
        let state = BaseLabelFadeState()
        state.rebind(change: set(3), time: 0)
        state.advance(targetVisibility: [true, true, true], time: 0, fadeInSeconds: 1, fadeOutSeconds: 1)
        state.advance(targetVisibility: [true, true, true], time: 0.5, fadeInSeconds: 1, fadeOutSeconds: 1)
        XCTAssertEqual(state.currentAlphas, [0.5, 0.5, 0.5])

        state.rebind(change: set(3, moves: [LabelBlockMove(oldStart: 1, newStart: 0, count: 1),
                                            LabelBlockMove(oldStart: 0, newStart: 2, count: 1)]),
                     time: 0.5)
        XCTAssertEqual(state.count, 3)
        XCTAssertEqual(state.currentAlphas, [0.5, 0, 0.5], "Alphas follow their runs; the newcomer starts invisible")

        state.advance(targetVisibility: [true, true, true], time: 1.0, fadeInSeconds: 1, fadeOutSeconds: 1)
        XCTAssertEqual(state.currentAlphas, [1, 0, 1], "The carried labels keep their stored target and finish the fade")
    }

    /// A tile of several labels moves as one block.
    func testARunMovesWhole() {
        let state = BaseLabelFadeState()
        state.rebind(change: set(4), time: 0)
        state.advance(targetVisibility: [false, true, true, false], time: 0, fadeInSeconds: 0, fadeOutSeconds: 0)
        state.advance(targetVisibility: [false, true, true, false], time: 1, fadeInSeconds: 0, fadeOutSeconds: 0)
        XCTAssertEqual(state.currentAlphas, [0, 1, 1, 0])

        state.rebind(change: set(5, moves: [LabelBlockMove(oldStart: 1, newStart: 3, count: 2)]), time: 1)
        XCTAssertEqual(state.currentAlphas, [0, 0, 0, 1, 1])
    }

    /// A stale move past either end reads and writes only what fits.
    func testAMovePastTheEndIsClipped() {
        let state = BaseLabelFadeState()
        state.rebind(change: set(2), time: 0)
        state.advance(targetVisibility: [true, true], time: 0, fadeInSeconds: 0, fadeOutSeconds: 0)
        state.advance(targetVisibility: [true, true], time: 1, fadeInSeconds: 0, fadeOutSeconds: 0)

        state.rebind(change: set(2, moves: [LabelBlockMove(oldStart: 1, newStart: 1, count: 5)]), time: 1)
        XCTAssertEqual(state.currentAlphas, [0, 1])
    }

    /// The solve found the second label to be a copy of the first, from a
    /// coarser tile: the shown copy's alpha goes to the winner and the
    /// copy goes out at once, so the feature never draws twice.
    func testTransferHandsTheFullerAlphaToTheWinnerAndHidesTheLoser() {
        let state = BaseLabelFadeState()
        state.rebind(change: set(2), time: 0)
        state.advance(targetVisibility: [false, true], time: 0, fadeInSeconds: 0, fadeOutSeconds: 0)
        state.advance(targetVisibility: [false, true], time: 1, fadeInSeconds: 0, fadeOutSeconds: 0)
        XCTAssertEqual(state.currentAlphas, [0, 1])

        state.transfer(from: 1, to: 0)
        XCTAssertEqual(state.currentAlphas, [1, 0])

        // The winner already fuller keeps its own alpha; the loser still goes.
        state.advance(targetVisibility: [true, true], time: 1, fadeInSeconds: 1, fadeOutSeconds: 1)
        state.advance(targetVisibility: [true, true], time: 1.5, fadeInSeconds: 1, fadeOutSeconds: 1)
        XCTAssertEqual(state.currentAlphas, [1, 0.5])
        state.transfer(from: 1, to: 0)
        XCTAssertEqual(state.currentAlphas, [1, 0])
    }

    /// A zoom step: the parent tile (keys 1, 2, 3) leaves and the exact
    /// tile (keys 9, 2, 1) arrives in one change. No run survives, but the
    /// labels lit in the tile that left keep their fade in the tile that
    /// arrived, matched by key. The unlit one and the new one start over.
    func testALitLabelKeepsItsFadeWhenItsTileIsSwapped() {
        let state = BaseLabelFadeState()
        state.rebind(change: set(3), time: 0)
        state.advance(targetVisibility: [true, true, false], time: 0, fadeInSeconds: 0, fadeOutSeconds: 0)
        state.advance(targetVisibility: [true, true, false], time: 1, fadeInSeconds: 0, fadeOutSeconds: 0)
        XCTAssertEqual(state.currentAlphas, [1, 1, 0])

        let change = LabelWorkingSetChange(count: 3,
                                           moves: [],
                                           departedRuns: [0..<3],
                                           arrivedRuns: [0..<3],
                                           previousKeys: [1, 2, 3],
                                           keys: [9, 2, 1])
            .seeded(oldAlphas: state.currentAlphas, threshold: 0.0001)
        XCTAssertEqual(Set(change.moves.map(\.newStart)), [1, 2])
        state.rebind(change: change, time: 1)
        XCTAssertEqual(state.currentAlphas, [0, 1, 1])

        // The carried target holds: the next frame moves nothing.
        state.advance(targetVisibility: [true, true, true], time: 1.1, fadeInSeconds: 1, fadeOutSeconds: 1)
        XCTAssertEqual(state.currentAlphas[1], 1)
        XCTAssertEqual(state.currentAlphas[2], 1)
    }

    /// A copy that arrives beside a lit copy of its feature takes over at
    /// once, wherever the lit copy is: here key 6 is lit in tile A, which
    /// stays, and key 7 in two tiles that leave, where the fullest seeds.
    func testAnArrivingLabelIsSeededFromAnyLitCopy() {
        // Old span: tile A [5, 6] stays, tile B [7] and tile C [7] leave.
        // New span: tile A [5, 6], tile D [6, 7] arrives.
        let change = LabelWorkingSetChange(count: 4,
                                           moves: [LabelBlockMove(oldStart: 0, newStart: 0, count: 2)],
                                           departedRuns: [2..<3, 3..<4],
                                           arrivedRuns: [2..<4],
                                           previousKeys: [5, 6, 7, 7],
                                           keys: [5, 6, 6, 7])
            .seeded(oldAlphas: [1, 1, 0.25, 0.75], threshold: 0.0001)
        XCTAssertEqual(change.moves, [LabelBlockMove(oldStart: 0, newStart: 0, count: 2),
                                      LabelBlockMove(oldStart: 1, newStart: 2, count: 1),
                                      LabelBlockMove(oldStart: 3, newStart: 3, count: 1)])
        XCTAssertEqual(change.carry([Float](arrayLiteral: 1, 1, 0.25, 0.75), initial: 0), [1, 1, 1, 0.75])
    }

    /// The sequence that blinked: the exact tile arrived a frame ago and
    /// its copy is still unlit (the buildings have not answered for it),
    /// and now the parent leaves with the copy that was showing. The unlit
    /// copy in the tile that stays takes the fade over. A label lit in the
    /// tile that stays keeps its own, and an unlit one whose key nobody
    /// lit stays unlit.
    func testAnUnlitLabelOfASurvivingTileTakesOverACopyThatLeft() {
        // Old span: child [7, 8, 9] at 0, parent [7, 9] at 3. The parent leaves.
        let change = LabelWorkingSetChange(count: 3,
                                           moves: [LabelBlockMove(oldStart: 0, newStart: 0, count: 3)],
                                           departedRuns: [3..<5],
                                           arrivedRuns: [],
                                           previousKeys: [7, 8, 9, 7, 9],
                                           keys: [7, 8, 9])
            .seeded(oldAlphas: [0, 0, 0.5, 1, 1], threshold: 0.0001)
        XCTAssertEqual(change.moves, [LabelBlockMove(oldStart: 0, newStart: 0, count: 3),
                                      LabelBlockMove(oldStart: 3, newStart: 0, count: 1)])
        XCTAssertEqual(change.carry([Float](arrayLiteral: 0, 0, 0.5, 1, 1), initial: 0), [1, 0, 0.5])
    }

    /// A change that neither brings a tile nor loses a lit label has
    /// nothing to seed and is handed back as it came.
    func testNothingToSeedLeavesTheChangeAlone() {
        let moves = [LabelBlockMove(oldStart: 0, newStart: 0, count: 2)]
        XCTAssertEqual(LabelWorkingSetChange(count: 2, moves: moves, previousKeys: [1, 2], keys: [1, 2])
            .seeded(oldAlphas: [1, 0], threshold: 0.0001).moves, moves)
        XCTAssertEqual(LabelWorkingSetChange(count: 2, moves: moves, departedRuns: [2..<3],
                                             previousKeys: [1, 2, 2], keys: [1, 2])
            .seeded(oldAlphas: [1, 0, 0], threshold: 0.0001).moves, moves,
                       "The label that left was not lit")
    }

    func testRebindWithIdentityMovesKeepsEverything() {
        let state = BaseLabelFadeState()
        state.rebind(change: set(2), time: 0)
        state.advance(targetVisibility: [true, false], time: 0, fadeInSeconds: 0, fadeOutSeconds: 0)
        state.advance(targetVisibility: [true, false], time: 1, fadeInSeconds: 0, fadeOutSeconds: 0)
        state.rebind(change: set(2, moves: [LabelBlockMove(oldStart: 0, newStart: 0, count: 2)]), time: 5)
        XCTAssertEqual(state.currentAlphas, [1, 0])
    }
}
