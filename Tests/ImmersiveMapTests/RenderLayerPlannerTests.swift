// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class RenderLayerPlannerTests: XCTestCase {
    func testFlatModePlansWorldLayersBeforeEnabledOverlays() {
        let plan = RenderLayerPlanner.plan(
            availability: RenderPassAvailability(renderSurfaceMode: .flat,
                                                 labelsEnabled: true,
                                                 avatarsEnabled: true,
                                                 debugOverlayEnabled: true,
                                                 sceneModelOcclusionEnabled: true,
                                                 starfieldEnabled: true)
        )

        XCTAssertEqual(plan.map(\.layer), [
            .tileOwnership,
            .flatMapSurface,
            .buildingExtrusion,
            .sceneModels,
            .horizon,
            .sceneModelOcclusion,
            .labels,
            .avatars,
            .debugOverlay
        ])
        XCTAssertTrue(plan.allSatisfy(\.enabled))
        XCTAssertFalse(plan.map(\.layer).contains(.buildingImage))
        // Routes are a globe-only feature in this version, and the plan is
        // where that invariant is enforced.
        XCTAssertFalse(plan.map(\.layer).contains(.routes))
        XCTAssertFalse(plan.map(\.layer).contains(.globeVectorSurface))
    }

    func testFlatModeKeepsOverlayPlanItemsDisabledWhenUnavailable() {
        let plan = RenderLayerPlanner.plan(
            availability: RenderPassAvailability(renderSurfaceMode: .flat,
                                                 labelsEnabled: false,
                                                 avatarsEnabled: false,
                                                 debugOverlayEnabled: false,
                                                 sceneModelOcclusionEnabled: false,
                                                 starfieldEnabled: true)
        )

        XCTAssertEqual(plan.map(\.layer), [
            .tileOwnership,
            .flatMapSurface,
            .buildingExtrusion,
            .sceneModels,
            .horizon,
            .sceneModelOcclusion,
            .labels,
            .avatars,
            .debugOverlay
        ])
        XCTAssertEqual(enabledLayers(in: plan), [.tileOwnership, .flatMapSurface, .buildingExtrusion, .sceneModels, .horizon])
        XCTAssertEqual(skipReason(for: .sceneModelOcclusion, in: plan), .noSceneModelContent)
        XCTAssertEqual(skipReason(for: .labels, in: plan), .noLabelContent)
        XCTAssertEqual(skipReason(for: .avatars, in: plan), .noAvatarContent)
        XCTAssertEqual(skipReason(for: .debugOverlay, in: plan), .debugOverlayDisabled)
    }

    func testGlobeModePlansWorldLayersBeforeEnabledOverlays() {
        let plan = RenderLayerPlanner.plan(
            availability: RenderPassAvailability(renderSurfaceMode: .spherical,
                                                 labelsEnabled: true,
                                                 avatarsEnabled: true,
                                                 debugOverlayEnabled: true,
                                                 sceneModelOcclusionEnabled: true,
                                                 starfieldEnabled: true)
        )

        XCTAssertEqual(plan.map(\.layer), [
            .starfield,
            .globeVectorSurface,
            .globeCap,
            .sceneModels,
            .routes,
            .horizon,
            .sceneModelOcclusion,
            .labels,
            .avatars,
            .debugOverlay
        ])
        XCTAssertTrue(plan.allSatisfy(\.enabled))
        XCTAssertFalse(plan.map(\.layer).contains(.buildingImage))
    }

    func testGlobeModeKeepsOverlayPlanItemsDisabledWhenUnavailable() {
        let plan = RenderLayerPlanner.plan(
            availability: RenderPassAvailability(renderSurfaceMode: .spherical,
                                                 labelsEnabled: false,
                                                 avatarsEnabled: false,
                                                 debugOverlayEnabled: false,
                                                 sceneModelOcclusionEnabled: false,
                                                 starfieldEnabled: true)
        )

        XCTAssertEqual(plan.map(\.layer), [
            .starfield,
            .globeVectorSurface,
            .globeCap,
            .sceneModels,
            .routes,
            .horizon,
            .sceneModelOcclusion,
            .labels,
            .avatars,
            .debugOverlay
        ])
        XCTAssertEqual(enabledLayers(in: plan), [.starfield, .globeVectorSurface, .globeCap, .sceneModels, .routes, .horizon])
        XCTAssertEqual(skipReason(for: .sceneModelOcclusion, in: plan), .noSceneModelContent)
        XCTAssertEqual(skipReason(for: .labels, in: plan), .noLabelContent)
        XCTAssertEqual(skipReason(for: .avatars, in: plan), .noAvatarContent)
        XCTAssertEqual(skipReason(for: .debugOverlay, in: plan), .debugOverlayDisabled)
    }

    /// The occlusion prepass only serves the labels: with none to draw it is
    /// off even when models are on screen, and the skip is not double-reported
    /// (the labels item already reports the missing label content).
    func testSceneModelOcclusionIsDisabledWithoutLabels() {
        let plan = RenderLayerPlanner.plan(
            availability: RenderPassAvailability(renderSurfaceMode: .spherical,
                                                 labelsEnabled: false,
                                                 avatarsEnabled: false,
                                                 debugOverlayEnabled: false,
                                                 sceneModelOcclusionEnabled: true,
                                                 starfieldEnabled: true)
        )

        let occlusionItem = plan.first { $0.layer == .sceneModelOcclusion }
        XCTAssertEqual(occlusionItem?.enabled, false)
        XCTAssertNil(occlusionItem?.skipReason)
    }

    /// Labels keep drawing when no models are on screen: only the occlusion
    /// prepass is skipped, reported as missing scene model content.
    func testSceneModelOcclusionIsDisabledWithoutModels() {
        let plan = RenderLayerPlanner.plan(
            availability: RenderPassAvailability(renderSurfaceMode: .flat,
                                                 labelsEnabled: true,
                                                 avatarsEnabled: false,
                                                 debugOverlayEnabled: false,
                                                 sceneModelOcclusionEnabled: false,
                                                 starfieldEnabled: true)
        )

        let occlusionItem = plan.first { $0.layer == .sceneModelOcclusion }
        XCTAssertEqual(occlusionItem?.enabled, false)
        XCTAssertEqual(occlusionItem?.skipReason, .noSceneModelContent)
        XCTAssertTrue(enabledLayers(in: plan).contains(.labels))
    }

    /// The occlusion prepass must run inside the overlay pass: its depth
    /// writes land in the overlay depth attachment the labels test against.
    func testSceneModelOcclusionIsAnOverlayLayer() {
        XCTAssertTrue(RenderPassGraph.isOverlayLayer(.sceneModelOcclusion))
        XCTAssertFalse(RenderPassGraph.isWorldLayer(.sceneModelOcclusion))
    }

    /// Transparent space keeps the starfield in the plan but disabled: nothing
    /// outside the globe is painted, and the skip is reported as such.
    func testTransparentSpaceDisablesTheStarfieldLayer() {
        let plan = RenderLayerPlanner.plan(
            availability: RenderPassAvailability(renderSurfaceMode: .spherical,
                                                 labelsEnabled: true,
                                                 avatarsEnabled: true,
                                                 debugOverlayEnabled: true,
                                                 sceneModelOcclusionEnabled: true,
                                                 starfieldEnabled: false)
        )

        XCTAssertEqual(enabledLayers(in: plan), [
            .globeVectorSurface,
            .globeCap,
            .sceneModels,
            .routes,
            .horizon,
            .sceneModelOcclusion,
            .labels,
            .avatars,
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
                                                     avatarsEnabled: true,
                                                     debugOverlayEnabled: true,
                                                     sceneModelOcclusionEnabled: true,
                                                     starfieldEnabled: false)
            )
            let worldLayers = plan.map(\.layer).filter(RenderPassGraph.isWorldLayer)
            XCTAssertEqual(worldLayers.last, .horizon, "\(mode)")
            XCTAssertEqual(plan.first { $0.layer == .horizon }?.enabled, true, "\(mode)")
        }
        XCTAssertTrue(RenderPassGraph.isWorldLayer(.horizon))
        XCTAssertFalse(RenderPassGraph.isOverlayLayer(.horizon))
    }



    private func enabledLayers(in plan: [RenderLayerPlanItem]) -> [RenderLayer] {
        plan.filter(\.enabled).map(\.layer)
    }

    private func skipReason(for layer: RenderLayer,
                            in plan: [RenderLayerPlanItem]) -> RenderSkipReason? {
        plan.first { $0.layer == layer }?.skipReason
    }
}
