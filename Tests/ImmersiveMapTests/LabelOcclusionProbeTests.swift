// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The buildings' answer about each point label, carried across a change
/// of the working set with each surviving tile's run, the way the fades
/// carry their alphas. The GPU half (the probes in the world pass) is
/// looked at in the visual review, scenario `labels.occlusion.moscow`.
final class LabelOcclusionProbeTests: XCTestCase {
    /// Three tiles of one label each, reordered: every answer follows its
    /// run to its new index.
    func testASurvivingRunKeepsItsAnswersAtItsNewIndex() {
        let change = LabelWorkingSetChange(count: 3, moves: [LabelBlockMove(oldStart: 0, newStart: 1, count: 1),
                                                             LabelBlockMove(oldStart: 1, newStart: 2, count: 1),
                                                             LabelBlockMove(oldStart: 2, newStart: 0, count: 1)])
        XCTAssertEqual(change.carry([true, false, true], initial: true), [true, true, false])
    }

    /// While the probe runs a label new to the set is hidden until its
    /// first answer, so it fades in once, in view, rather than appearing
    /// over a building and fading out again. With the probe off it is in
    /// view, so switching the probe on hides nothing that was shown.
    func testANewLabelIsHiddenUntilAnsweredOnlyWhileTheProbeRuns() {
        let change = LabelWorkingSetChange(count: 2, moves: [LabelBlockMove(oldStart: 0, newStart: 0, count: 1)])
        XCTAssertEqual(change.carry([false], initial: true), [false, true])
        XCTAssertEqual(change.carry([false], initial: false), [false, false])
    }

    /// A tile of several labels moves as one block, and a stale move past
    /// either end carries only what fits.
    func testARunMovesWholeAndAMovePastTheEndIsClipped() {
        let whole = LabelWorkingSetChange(count: 4, moves: [LabelBlockMove(oldStart: 1, newStart: 2, count: 2)])
        XCTAssertEqual(whole.carry([false, true, false, true], initial: false), [false, false, true, false])

        let clipped = LabelWorkingSetChange(count: 2, moves: [LabelBlockMove(oldStart: 1, newStart: 1, count: 4)])
        XCTAssertEqual(clipped.carry([true, true, true], initial: false), [false, true])
    }

    /// The probe input is what the shader reads (`LabelOcclusionProbeInput`
    /// in LabelOcclusionProbe.metal): a packed position, the roof, the
    /// flag and padding to 32 bytes.
    func testTheProbeInputKeepsTheShaderLayout() {
        XCTAssertEqual(MemoryLayout<LabelOcclusionProbe.Input>.stride, 32)
        XCTAssertEqual(MemoryLayout<LabelOcclusionProbe.Input>.offset(of: \.roofZ), 12)
        XCTAssertEqual(MemoryLayout<LabelOcclusionProbe.Input>.offset(of: \.enabled), 16)
    }
}

/// The world's depth the buildings paint over the road names with.
final class RoadLabelSceneDepthTests: XCTestCase {
    /// The uniforms are what the road text shaders read
    /// (`RoadLabelSceneDepthUniforms` in LabelTextCommon.h).
    func testTheUniformsKeepTheShaderLayout() {
        XCTAssertEqual(MemoryLayout<RoadLabelSceneDepthUniforms>.offset(of: \.eye), 128)
        XCTAssertEqual(MemoryLayout<RoadLabelSceneDepthUniforms>.offset(of: \.viewportSize), 144)
        XCTAssertEqual(MemoryLayout<RoadLabelSceneDepthUniforms>.offset(of: \.enabled), 152)
        XCTAssertEqual(MemoryLayout<RoadLabelSceneDepthUniforms>.stride, 160)
    }
}
