// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// How the buildings and the models rise out of the ground part by part,
/// and go when the camera leaves their zoom (`ExtrusionRise`).
final class ExtrusionRiseTests: XCTestCase {
    /// A map opened at a street zoom shows the parts of its first frame
    /// standing.
    func testTheFirstFrameStandsAtOnce() {
        var rise = ExtrusionRise<Int>()
        rise.advance(keys: [1, 2], time: 10, seconds: 0.6)

        XCTAssertEqual(rise.heightScale(of: 1, time: 10), 1)
        XCTAssertEqual(rise.heightScale(of: 2, time: 10), 1)
        XCTAssertFalse(rise.isAnimating)
    }

    /// A part first drawn later, a tile that arrives with the camera
    /// already at the zoom, rises on its own over the seconds, eased out,
    /// while the parts already there keep standing.
    func testAPartArrivingLaterRisesOnItsOwn() {
        var rise = ExtrusionRise<Int>()
        rise.advance(keys: [1], time: 0, seconds: 0.6)
        rise.advance(keys: [1, 2], time: 1, seconds: 0.6)
        XCTAssertEqual(rise.heightScale(of: 2, time: 1), 0, "It starts from the ground")
        XCTAssertTrue(rise.isAnimating)

        rise.advance(keys: [1, 2], time: 1.3, seconds: 0.6)
        XCTAssertEqual(rise.heightScale(of: 1, time: 1.3), 1)
        XCTAssertEqual(rise.progress(of: 2, time: 1.3), 0.5, accuracy: 1e-6)
        XCTAssertEqual(rise.heightScale(of: 2, time: 1.3), 0.875, accuracy: 1e-6,
                       "Eased out: past the halfway height at half the time")

        rise.advance(keys: [1, 2], time: 1.6, seconds: 0.6)
        XCTAssertEqual(rise.heightScale(of: 2, time: 1.6), 1, accuracy: 1e-6)
        XCTAssertFalse(rise.isAnimating)
    }

    /// Leaving the zoom (no parts drawn), everything is gone at once, and
    /// coming back it rises from the ground again.
    func testLeavingTheZoomDropsEveryPartAtOnce() {
        var rise = ExtrusionRise<Int>()
        rise.advance(keys: [1], time: 0, seconds: 0.5)
        rise.advance(keys: [], time: 0.1, seconds: 0.5)
        XCTAssertEqual(rise.heightScale(of: 1, time: 0.1), 0)
        XCTAssertFalse(rise.isAnimating)

        rise.advance(keys: [1], time: 0.2, seconds: 0.5)
        XCTAssertEqual(rise.heightScale(of: 1, time: 0.2), 0)
        XCTAssertTrue(rise.isAnimating)
    }

    /// Zero seconds stands every part up at once.
    func testZeroSecondsStandsEveryPartAtOnce() {
        var rise = ExtrusionRise<Int>()
        rise.advance(keys: [], time: 0, seconds: 0)
        rise.advance(keys: [1], time: 0.01, seconds: 0)
        XCTAssertEqual(rise.heightScale(of: 1, time: 0.01), 1)
        XCTAssertFalse(rise.isAnimating)
    }

    /// The buildings of a map tile wait for the model tile it lies in, of
    /// whichever level of detail is on its way, and a map tile coarser
    /// than that model tile does not.
    func testAMapTileWaitsForTheModelTileItLiesIn() {
        var state = ModelTileFrameState()
        XCTAssertFalse(state.isPending(over: Tile(x: 9651, y: 12319, z: 15)))

        state.pendingTiles = [Tile(x: 4825, y: 6159, z: 14)]
        XCTAssertTrue(state.isPending(over: Tile(x: 9651, y: 12319, z: 15)))
        XCTAssertTrue(state.isPending(over: Tile(x: 4825, y: 6159, z: 14)))
        XCTAssertFalse(state.isPending(over: Tile(x: 4826, y: 6159, z: 14)))
        XCTAssertFalse(state.isPending(over: Tile(x: 2412, y: 3079, z: 13)), "Coarser than the model tile")

        state.pendingTiles = [Tile(x: 1206, y: 1539, z: 12)]
        XCTAssertTrue(state.isPending(over: Tile(x: 9651, y: 12319, z: 15)))
        XCTAssertTrue(state.isPending(over: Tile(x: 2412, y: 3079, z: 13)))
    }
}
