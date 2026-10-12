// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The world pass draws the solid buildings before the ground, so the ground
/// under them fails its depth test unshaded. There is no other building
/// path: translucent compositing was removed.
final class RenderPassGraphWorldLayerOrderTests: XCTestCase {
    private let flatPlan: [RenderLayer] = [.flatMapSurface, .buildingExtrusion, .sceneModels, .horizon]

    func testBuildingsDrawBeforeTheGround() {
        XCTAssertEqual(RenderPassGraph.worldLayerOrder(flatPlan),
                       [.buildingExtrusion, .flatMapSurface, .sceneModels, .horizon])
    }

    /// With extrusion off the planner leaves the building layer out, and
    /// the order has nothing to flip.
    func testExtrusionOffLeavesTheGroundFirst() {
        let plan: [RenderLayer] = [.flatMapSurface, .sceneModels, .horizon]
        XCTAssertEqual(RenderPassGraph.worldLayerOrder(plan), plan)
    }

    func testGlobeLayersAreLeftAlone() {
        let globePlan: [RenderLayer] = [.starfield, .globeVectorSurface, .globeCap, .sceneModels, .horizon]
        XCTAssertEqual(RenderPassGraph.worldLayerOrder(globePlan), globePlan)
    }

    func testAlreadyOrderedPlanIsUnchanged() {
        let ordered: [RenderLayer] = [.buildingExtrusion, .flatMapSurface, .sceneModels, .horizon]
        XCTAssertEqual(RenderPassGraph.worldLayerOrder(ordered), ordered)
    }
}
