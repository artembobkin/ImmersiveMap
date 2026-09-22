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
        XCTAssertEqual(sets.rules(forTargetZoom: 0), near.normalized())
        XCTAssertEqual(sets.rules(forTargetZoom: 7), near.normalized())
        XCTAssertEqual(sets.rules(forTargetZoom: 8), far.normalized())
        XCTAssertEqual(sets.rules(forTargetZoom: 16), far.normalized())
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

    /// A set carries its own tuning, and a frame reads its set's: the
    /// raster zone, the road fade and the building areas, kept in order.
    func testAFrameReadsItsSetsTuning() {
        var sets = RingRuleSets(sets: [RingRuleSet(firstZoom: 0, rules: near), RingRuleSet(firstZoom: 8, rules: far)])
        sets.sets[0].tuning.rasterZone.startCameraDistances = 3
        sets.sets[1].tuning.roadThinnessFade = .off
        sets.sets[1].tuning.buildingGoneAreaPixels = 900
        sets.sets[1].tuning.buildingOpaqueAreaPixels = 100
        XCTAssertEqual(sets.tuning(forTargetZoom: 5).rasterZone.startCameraDistances, 3)
        XCTAssertEqual(sets.tuning(forTargetZoom: 12).rasterZone, .default)
        XCTAssertEqual(sets.tuning(forTargetZoom: 5).roadThinnessFade, .default)
        XCTAssertEqual(sets.tuning(forTargetZoom: 12).roadThinnessFade, .off)
        XCTAssertEqual(sets.tuning(forTargetZoom: 12).buildingOpaqueAreaPixels, 900, "never whole under the area it is gone at")
    }

    /// The globe's zooms and the street zooms are tuned apart: the default
    /// splits where the default presentation finishes the unroll.
    func testTheDefaultSplitsAtTheEndOfTheUnroll() {
        let sets = RingRuleSets.default
        XCTAssertEqual(sets.sets.map(\.firstZoom), [0, 7])
        XCTAssertEqual(sets.rules(forTargetZoom: 6), FlatRingRules.globeDefault)
        XCTAssertEqual(sets.rules(forTargetZoom: 7), FlatRingRules.default)
        XCTAssertEqual(FlatRingRules.globeDefault.rules.map(\.rasterized), [true, false],
                       "the exact tiles turn into pictures where the zone says, the coarse band stays geometry")
        XCTAssertEqual(FlatRingRules.globeDefault.rules.map(\.rasterResolution), [256, 256])
        XCTAssertEqual(FlatRingRules.globeDefault.rules.map(\.zoomDrop), [0, 2])
        XCTAssertEqual(FlatRingRules.globeDefault.rules.map(\.distance), [1, 3])
        XCTAssertEqual(sets.tuning(forTargetZoom: 6).rasterZone.startCameraDistances, 0.72)
        XCTAssertEqual(sets.tuning(forTargetZoom: 7).rasterZone, .default)
        XCTAssertEqual(FlatRingRules.globeDefault.rules.map(\.drawsLines), [true, false])
    }
}
