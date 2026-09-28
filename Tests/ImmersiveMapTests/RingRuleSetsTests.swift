// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The ring rules by target zoom: which set a frame reads, and the shape
/// the sets are kept in.
final class RingRuleSetsTests: XCTestCase {
    private let near = FlatRingRules(rules: [FlatRingRule(zoomDrop: 0, distance: 2)])
    private let far = FlatRingRules(rules: [FlatRingRule(zoomDrop: 1, distance: 5)])

    /// A set owns the zooms from its first to the next set's, the last set
    /// everything deeper.
    func testAFrameReadsTheSetItsZoomFallsIn() {
        let sets = RingRuleSets(sets: [RingRuleSet(firstZoom: 0, rules: near), RingRuleSet(firstZoom: 8, rules: far)])
        XCTAssertEqual(sets.rules(forZoom: 0), near.normalized())
        XCTAssertEqual(sets.rules(forZoom: 7), near.normalized())
        XCTAssertEqual(sets.rules(forZoom: 8), far.normalized())
        XCTAssertEqual(sets.rules(forZoom: 16), far.normalized())
        XCTAssertEqual(sets.lastZoom(ofSetAt: 0), 7)
        XCTAssertNil(sets.lastZoom(ofSetAt: 1))
    }

    /// Sorted, one set per first zoom, the first from zoom 0, the rules
    /// normalized, never empty.
    func testTheSetsAreKeptInOrder() {
        let wild = RingRuleSets(sets: [RingRuleSet(firstZoom: 9, rules: far),
                                       RingRuleSet(firstZoom: 3, rules: near),
                                       RingRuleSet(firstZoom: 9, rules: near),
                                       RingRuleSet(firstZoom: 99, rules: far)]).normalized()
        XCTAssertEqual(wild.sets.map(\.firstZoom), [0, 9, RingRuleSets.zoomRange.upperBound])
        XCTAssertEqual(wild.sets[0].rules, near.normalized(), "the lowest set takes the zooms under it")
        XCTAssertEqual(RingRuleSets(sets: []).normalized(), RingRuleSets.default)
        XCTAssertEqual(RingRuleSets.default.normalized(), RingRuleSets.default, "the default is already normal")
    }

    /// The globe's zooms and the street zooms take different rules: the
    /// default splits where the default presentation finishes the unroll,
    /// and again among the buildings and closer still.
    func testTheDefaultSplitsAtTheEndOfTheUnrollAndAmongTheBuildings() {
        let sets = RingRuleSets.default
        XCTAssertEqual(sets.sets.map(\.firstZoom), [0, 7, 15, 17])
        XCTAssertEqual(sets.rules(forZoom: 6), FlatRingRules.globeDefault)
        XCTAssertEqual(sets.rules(forZoom: 7), FlatRingRules.default)
        XCTAssertEqual(sets.rules(forZoom: 14), FlatRingRules.default)
        XCTAssertEqual(sets.rules(forZoom: 16), FlatRingRules.nearStreetDefault)
        XCTAssertEqual(sets.rules(forZoom: 17), FlatRingRules.closeStreetDefault)
        XCTAssertEqual(sets.rules(forZoom: 22), FlatRingRules.closeStreetDefault)

        let near = FlatRingRules.nearStreetDefault.rules
        XCTAssertEqual(near.map(\.zoomDrop), [0, 1, 5])
        XCTAssertEqual(near.map(\.distance), [1, 2, 3])
        XCTAssertEqual(near.map(\.drawsLines), [true, true, true])
        XCTAssertEqual(near.map(\.drawsLabels), [true, false, false])
        let close = FlatRingRules.closeStreetDefault.rules
        XCTAssertEqual(close.map(\.zoomDrop), [0, 2])
        XCTAssertEqual(close.map(\.distance), [1, 2])
        XCTAssertEqual(close.map(\.drawsLines), [true, true])
        XCTAssertEqual(close.map(\.drawsLabels), [true, false])
        XCTAssertEqual(FlatRingRules.nearStreetDefault.normalized(), .nearStreetDefault)
        XCTAssertEqual(FlatRingRules.closeStreetDefault.normalized(), .closeStreetDefault)
        XCTAssertEqual(FlatRingRules.globeDefault.rules.map(\.zoomDrop), [0, 2])
        XCTAssertEqual(FlatRingRules.globeDefault.rules.map(\.distance), [1, 3])
        XCTAssertEqual(FlatRingRules.globeDefault.rules.map(\.drawsLines), [true, false])
    }

    /// A set starting past the tileset's deepest zoom is reached: the set
    /// is chosen by the camera zoom, which goes on past the tiles, not by
    /// the target zoom, which stops at them.
    func testASetPastTheDeepestTileZoomIsChosenByTheCameraZoom() {
        let deep = FlatRingRules(rules: [FlatRingRule(zoomDrop: 0, distance: 0, drawsLines: false, drawsLabels: false)])
        let sets = RingRuleSets(sets: [RingRuleSet(firstZoom: 0, rules: .globeDefault),
                                       RingRuleSet(firstZoom: 7, rules: .default),
                                       RingRuleSet(firstZoom: 16, rules: deep)])
        XCTAssertEqual(RenderFrameVisibilityResolver.ruleSetZoom(cameraZoom: 16.4), 16)
        XCTAssertEqual(sets.rules(forZoom: RenderFrameVisibilityResolver.ruleSetZoom(cameraZoom: 16.4)), deep)
        XCTAssertEqual(sets.rules(forZoom: RenderFrameVisibilityResolver.ruleSetZoom(cameraZoom: 15.9)), .default)
        XCTAssertEqual(RenderFrameVisibilityResolver.ruleSetZoom(cameraZoom: -1), 0)
        XCTAssertEqual(RenderFrameVisibilityResolver.ruleSetZoom(cameraZoom: 40), RingRuleSets.zoomRange.upperBound)
    }
}
