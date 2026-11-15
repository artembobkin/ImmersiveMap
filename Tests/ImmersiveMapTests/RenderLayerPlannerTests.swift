// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class RenderLayerPlannerTests: XCTestCase {
    func testFlatModePlansWorldLayersBeforeEnabledOverlays() {
        let plan = RenderLayerPlanner.plan(
            availability: RenderPassAvailability(renderSurfaceMode: .flat,
                                                 labelsEnabled: true,
                                                 pinsEnabled: true,
                                                 debugOverlayEnabled: true,
                                                 starfieldEnabled: true)
        )

        XCTAssertEqual(plan.map(\.layer), [
            .placementStencil,
            .flatMapSurface,
            .buildingExtrusion,
            .sceneModels,
            .flatMapRoads,
            .appLayers,
            .surfaceLabels,
            .horizon,
            .labels,
            .pins,
            .debugOverlay
        ])
        XCTAssertTrue(plan.allSatisfy(\.enabled))
        XCTAssertFalse(plan.map(\.layer).contains(.globeVectorSurface))
    }

    func testFlatModeKeepsOverlayPlanItemsDisabledWhenUnavailable() {
        let plan = RenderLayerPlanner.plan(
            availability: RenderPassAvailability(renderSurfaceMode: .flat,
                                                 labelsEnabled: false,
                                                 pinsEnabled: false,
                                                 debugOverlayEnabled: false,
                                                 starfieldEnabled: true)
        )

        XCTAssertEqual(plan.map(\.layer), [
            .placementStencil,
            .flatMapSurface,
            .buildingExtrusion,
            .sceneModels,
            .flatMapRoads,
            .appLayers,
            .surfaceLabels,
            .horizon,
            .labels,
            .pins,
            .debugOverlay
        ])
        XCTAssertEqual(enabledLayers(in: plan),
                       [.placementStencil, .flatMapSurface, .buildingExtrusion, .sceneModels, .flatMapRoads, .appLayers, .surfaceLabels, .horizon])
        XCTAssertEqual(skipReason(for: .labels, in: plan), .noLabelContent)
        XCTAssertEqual(skipReason(for: .pins, in: plan), .noPinContent)
        XCTAssertEqual(skipReason(for: .debugOverlay, in: plan), .debugOverlayDisabled)
    }

    func testGlobeModePlansWorldLayersBeforeEnabledOverlays() {
        let plan = RenderLayerPlanner.plan(
            availability: RenderPassAvailability(renderSurfaceMode: .spherical,
                                                 labelsEnabled: true,
                                                 pinsEnabled: true,
                                                 debugOverlayEnabled: true,
                                                 starfieldEnabled: true)
        )

        XCTAssertEqual(plan.map(\.layer), [
            .starfield,
            .placementStencil,
            .globeVectorSurface,
            .appLayers,
            .surfaceLabels,
            .globeCap,
            .sceneModels,
            .horizon,
            .labels,
            .pins,
            .debugOverlay
        ])
        XCTAssertTrue(plan.allSatisfy(\.enabled))
    }

    func testGlobeModeKeepsOverlayPlanItemsDisabledWhenUnavailable() {
        let plan = RenderLayerPlanner.plan(
            availability: RenderPassAvailability(renderSurfaceMode: .spherical,
                                                 labelsEnabled: false,
                                                 pinsEnabled: false,
                                                 debugOverlayEnabled: false,
                                                 starfieldEnabled: true)
        )

        XCTAssertEqual(plan.map(\.layer), [
            .starfield,
            .placementStencil,
            .globeVectorSurface,
            .appLayers,
            .surfaceLabels,
            .globeCap,
            .sceneModels,
            .horizon,
            .labels,
            .pins,
            .debugOverlay
        ])
        XCTAssertEqual(enabledLayers(in: plan), [.starfield, .placementStencil, .globeVectorSurface, .appLayers, .surfaceLabels, .globeCap, .sceneModels, .horizon])
        XCTAssertEqual(skipReason(for: .labels, in: plan), .noLabelContent)
        XCTAssertEqual(skipReason(for: .pins, in: plan), .noPinContent)
        XCTAssertEqual(skipReason(for: .debugOverlay, in: plan), .debugOverlayDisabled)
    }

    /// Transparent space keeps the starfield in the plan but disabled: nothing
    /// outside the globe is painted, and the skip is reported as such.
    func testTransparentSpaceDisablesTheStarfieldLayer() {
        let plan = RenderLayerPlanner.plan(
            availability: RenderPassAvailability(renderSurfaceMode: .spherical,
                                                 labelsEnabled: true,
                                                 pinsEnabled: true,
                                                 debugOverlayEnabled: true,
                                                 starfieldEnabled: false)
        )

        XCTAssertEqual(enabledLayers(in: plan), [
            .placementStencil,
            .globeVectorSurface,
            .appLayers,
            .surfaceLabels,
            .globeCap,
            .sceneModels,
            .horizon,
            .labels,
            .pins,
            .debugOverlay
        ])
        XCTAssertEqual(skipReason(for: .starfield, in: plan), .transparentSpace)
    }

    /// The horizon layer is planned on both surfaces and always enabled:
    /// the fog band and the limb feather are not optional, and whether the
    /// atmosphere's sky side draws is the subsystem's per-frame decision,
    /// not the planner's.
    func testTheHorizonLayerClosesTheWorldOnBothSurfaces() {
        for mode in [ViewMode.flat, .spherical] {
            let plan = RenderLayerPlanner.plan(
                availability: RenderPassAvailability(renderSurfaceMode: mode,
                                                     labelsEnabled: true,
                                                     pinsEnabled: true,
                                                     debugOverlayEnabled: true,
                                                     starfieldEnabled: false)
            )
            let worldLayers = plan.map(\.layer).filter(RenderPassGraph.isWorldLayer)
            XCTAssertEqual(worldLayers.last, .horizon, "\(mode)")
            XCTAssertEqual(plan.first { $0.layer == .horizon }?.enabled, true, "\(mode)")
        }
        XCTAssertTrue(RenderPassGraph.isWorldLayer(.horizon))
        XCTAssertFalse(RenderPassGraph.isOverlayLayer(.horizon))
    }


    /// No scene models on screen: the model layer is left out of the world
    /// pass on both surfaces instead of encoding an empty group.
    func testNoSceneModelsLeavesOutTheModelLayer() {
        for mode in [ViewMode.flat, .spherical] {
            let plan = RenderLayerPlanner.plan(
                availability: RenderPassAvailability(renderSurfaceMode: mode,
                                                     labelsEnabled: true,
                                                     pinsEnabled: false,
                                                     debugOverlayEnabled: false,
                                                     starfieldEnabled: true,
                                                     sceneModelsEnabled: false)
            )
            XCTAssertFalse(enabledLayers(in: plan).contains(.sceneModels), "\(mode)")
            XCTAssertEqual(skipReason(for: .sceneModels, in: plan), .noSceneModelContent, "\(mode)")
        }
    }

    private func enabledLayers(in plan: [RenderLayerPlanItem]) -> [RenderLayer] {
        plan.filter(\.enabled).map(\.layer)
    }

    private func skipReason(for layer: RenderLayer,
                            in plan: [RenderLayerPlanItem]) -> RenderSkipReason? {
        plan.first { $0.layer == layer }?.skipReason
    }
}
