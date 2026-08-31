// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The world pass draws solid buildings before the ground, so the ground
/// under them fails its depth test unshaded; composited buildings keep the
/// planner's ground-first order, since the ground has to be shaded where a
/// translucent building shows it through.
final class RenderPassGraphWorldLayerOrderTests: XCTestCase {
    private let flatPlan: [RenderLayer] = [.flatMapSurface, .buildingExtrusion, .sceneModels]

    func testSolidBuildingsDrawBeforeTheGround() {
        XCTAssertEqual(RenderPassGraph.worldLayerOrder(flatPlan, buildingPath: .solid),
                       [.buildingExtrusion, .flatMapSurface, .sceneModels])
    }

    func testCompositedBuildingsKeepTheGroundFirst() {
        XCTAssertEqual(RenderPassGraph.worldLayerOrder(flatPlan, buildingPath: .composited(alpha: 0.6)),
                       flatPlan)
    }

    func testGlobeLayersAreLeftAlone() {
        let globePlan: [RenderLayer] = [.globeSurface, .globeVectorSurface, .globeSurfaceLighting, .starfield,
                                        .atmosphere, .globeCap, .sceneModels, .routes]
        XCTAssertEqual(RenderPassGraph.worldLayerOrder(globePlan, buildingPath: nil), globePlan)
        XCTAssertEqual(RenderPassGraph.worldLayerOrder(globePlan, buildingPath: .solid), globePlan)
    }

    func testAlreadyOrderedPlanIsUnchanged() {
        let ordered: [RenderLayer] = [.buildingExtrusion, .flatMapSurface, .sceneModels]
        XCTAssertEqual(RenderPassGraph.worldLayerOrder(ordered, buildingPath: .solid), ordered)
    }
}
