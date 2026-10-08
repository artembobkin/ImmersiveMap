// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The labels' reach by camera zoom (`LabelDistanceRules`).
final class LabelDistanceRulesTests: XCTestCase {
    /// A frame reads the rule its camera zoom's whole part falls in.
    func testTheReachIsTheRuleOfTheCameraZoom() {
        let rules = LabelDistanceRules(rules: [
            LabelDistanceRule(firstZoom: 0, scale: .infinity),
            LabelDistanceRule(firstZoom: 15, scale: 2),
            LabelDistanceRule(firstZoom: 17, scale: 1.25)
        ]).normalized()

        XCTAssertEqual(rules.scale(forCameraZoom: 3), .infinity)
        XCTAssertEqual(rules.scale(forCameraZoom: 16.9), 2)
        XCTAssertEqual(rules.scale(forCameraZoom: 17), 1.25)
        XCTAssertEqual(rules.scale(forCameraZoom: 40), 1.25)
        XCTAssertEqual(rules.lastZoom(ofRuleAt: 1), 16)
        XCTAssertNil(rules.lastZoom(ofRuleAt: 2))
    }

    /// The rules as a frame reads them: sorted, one per first zoom, the
    /// first one from zoom 0, no negative or undefined reach.
    func testNormalizationCleansTheRules() {
        let rules = LabelDistanceRules(rules: [
            LabelDistanceRule(firstZoom: 12, scale: .nan),
            LabelDistanceRule(firstZoom: 5, scale: -1),
            LabelDistanceRule(firstZoom: 12, scale: 3)
        ]).normalized()

        XCTAssertEqual(rules.rules, [LabelDistanceRule(firstZoom: 0, scale: 0),
                                     LabelDistanceRule(firstZoom: 12, scale: LabelDistanceRule.defaultScale)])
        XCTAssertEqual(LabelDistanceRules(rules: []).normalized(), .default)
    }
}
