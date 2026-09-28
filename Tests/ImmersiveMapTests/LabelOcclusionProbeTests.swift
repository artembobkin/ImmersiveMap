// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The buildings' answer about each point label, carried across a change
/// of the working set by label key, the way the fades carry their alphas.
/// The GPU half (the probes in the world pass) is looked at in the visual
/// review, scenario `labels.occlusion.moscow`.
final class LabelOcclusionProbeTests: XCTestCase {
    func testAKeyOfTheOldSetKeepsItsAnswerAtItsNewIndex() {
        let carried = LabelOcclusionProbe.carriedAnswers(keys: [1, 2, 3],
                                                         occluded: [true, false, true],
                                                         newKeys: [3, 1, 2],
                                                         unknownOccluded: true)
        XCTAssertEqual(carried, [true, true, false])
    }

    /// While the probe runs a label new to the set is hidden until its
    /// first answer, so it fades in once, in view, rather than appearing
    /// over a building and fading out again. With the probe off it is in
    /// view, so switching the probe on hides nothing that was shown.
    func testANewKeyIsHiddenUntilAnsweredOnlyWhileTheProbeRuns() {
        XCTAssertEqual(LabelOcclusionProbe.carriedAnswers(keys: [1],
                                                          occluded: [false],
                                                          newKeys: [1, 2],
                                                          unknownOccluded: true),
                       [false, true])
        XCTAssertEqual(LabelOcclusionProbe.carriedAnswers(keys: [1],
                                                          occluded: [false],
                                                          newKeys: [1, 2],
                                                          unknownOccluded: false),
                       [false, false])
    }

    /// The same feature sits at two indices (an exact tile and the coarser
    /// tile standing in next to it): the copy in view wins, as the copy
    /// with the most alpha wins for the fades.
    func testTheCopyInViewWinsWhenAKeySitsAtSeveralIndices() {
        XCTAssertEqual(LabelOcclusionProbe.carriedAnswers(keys: [7, 7],
                                                          occluded: [true, false],
                                                          newKeys: [7],
                                                          unknownOccluded: true),
                       [false])
        XCTAssertEqual(LabelOcclusionProbe.carriedAnswers(keys: [7, 7],
                                                          occluded: [true, true],
                                                          newKeys: [7],
                                                          unknownOccluded: false),
                       [true])
    }

    /// The probe input is what the shader reads (`LabelOcclusionProbeInput`
    /// in LabelOcclusionProbe.metal): a packed position, the roof, the
    /// flag and padding to 32 bytes.
    func testTheProbeInputKeepsTheShaderLayout() {
        XCTAssertEqual(MemoryLayout<LabelOcclusionProbe.Input>.stride, 32)
        XCTAssertEqual(MemoryLayout<LabelOcclusionProbe.Input>.offset(of: \.roofZ), 12)
        XCTAssertEqual(MemoryLayout<LabelOcclusionProbe.Input>.offset(of: \.enabled), 16)
    }

    /// Key 0 is the cache's empty slot and carries nothing either way.
    func testTheEmptySlotCarriesNothing() {
        XCTAssertEqual(LabelOcclusionProbe.carriedAnswers(keys: [0, 1],
                                                          occluded: [false, false],
                                                          newKeys: [0, 1, 0],
                                                          unknownOccluded: true),
                       [true, false, true])
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
