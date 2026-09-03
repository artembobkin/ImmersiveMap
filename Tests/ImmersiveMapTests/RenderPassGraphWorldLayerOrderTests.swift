// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

/// The world pass draws solid buildings before the ground, so the ground
/// under them fails its depth test unshaded; composited buildings keep the
/// planner's ground-first order, since the ground has to be shaded where a
/// translucent building shows it through.
final class RenderPassGraphWorldLayerOrderTests: XCTestCase {
    private let flatPlan: [RenderLayer] = [.tileOwnership, .flatMapSurface, .buildingExtrusion, .sceneModels]

    func testSolidBuildingsDrawBeforeTheGround() {
        XCTAssertEqual(RenderPassGraph.worldLayerOrder(flatPlan, buildingPath: .solid),
                       [.tileOwnership, .buildingExtrusion, .flatMapSurface, .sceneModels])
    }

    /// The ownership prepass must precede the buildings in every flat
    /// order: it writes the stencil marks the buildings test.
    func testOwnershipPrepassStaysFirstOnBothBuildingPaths() {
        for path in [BuildingExtrusionPathResolver.Path.solid, .composited(alpha: 0.6)] {
            let ordered = RenderPassGraph.worldLayerOrder(flatPlan, buildingPath: path)
            XCTAssertEqual(ordered.first, .tileOwnership, "\(path)")
        }
        XCTAssertEqual(RenderLayerPlanner.plan(availability: RenderPassAvailability(
            renderSurfaceMode: .flat,
            labelsEnabled: false,
            avatarsEnabled: false,
            debugOverlayEnabled: false,
            sceneModelOcclusionEnabled: false,
            starfieldEnabled: true)).filter(\.enabled).map(\.layer).first, .tileOwnership,
                       "The planner lists the ownership prepass first among the flat world layers")
    }

    func testCompositedBuildingsKeepTheGroundFirst() {
        XCTAssertEqual(RenderPassGraph.worldLayerOrder(flatPlan, buildingPath: .composited(alpha: 0.6)),
                       flatPlan)
    }

    func testGlobeLayersAreLeftAlone() {
        let globePlan: [RenderLayer] = [.starfield, .globeVectorSurface, .globeCap, .sceneModels, .routes]
        XCTAssertEqual(RenderPassGraph.worldLayerOrder(globePlan, buildingPath: nil), globePlan)
        XCTAssertEqual(RenderPassGraph.worldLayerOrder(globePlan, buildingPath: .solid), globePlan)
    }

    func testAlreadyOrderedPlanIsUnchanged() {
        let ordered: [RenderLayer] = [.tileOwnership, .buildingExtrusion, .flatMapSurface, .sceneModels]
        XCTAssertEqual(RenderPassGraph.worldLayerOrder(ordered, buildingPath: .solid), ordered)
    }
}
