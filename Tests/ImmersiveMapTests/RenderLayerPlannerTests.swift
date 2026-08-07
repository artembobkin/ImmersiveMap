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
            .flatMapSurface,
            .buildingExtrusion,
            .sceneModels,
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
        // The globe surface layer, which also paints the placeholder fill under
        // the tile atlas, is absent here: the flat map has its own surface and
        // clears to the map color by itself.
        XCTAssertFalse(plan.map(\.layer).contains(.globeSurface))
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
            .flatMapSurface,
            .buildingExtrusion,
            .sceneModels,
            .sceneModelOcclusion,
            .labels,
            .avatars,
            .debugOverlay
        ])
        XCTAssertEqual(enabledLayers(in: plan), [.flatMapSurface, .buildingExtrusion, .sceneModels])
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
            .globeSurface,
            .globeCap,
            .sceneModels,
            .routes,
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
            .globeSurface,
            .globeCap,
            .sceneModels,
            .routes,
            .sceneModelOcclusion,
            .labels,
            .avatars,
            .debugOverlay
        ])
        XCTAssertEqual(enabledLayers(in: plan), [.starfield, .globeSurface, .globeCap, .sceneModels, .routes])
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
            .globeSurface,
            .globeCap,
            .sceneModels,
            .routes,
            .sceneModelOcclusion,
            .labels,
            .avatars,
            .debugOverlay
        ])
        XCTAssertEqual(skipReason(for: .starfield, in: plan), .transparentSpace)
    }

    private func enabledLayers(in plan: [RenderLayerPlanItem]) -> [RenderLayer] {
        plan.filter(\.enabled).map(\.layer)
    }

    private func skipReason(for layer: RenderLayer,
                            in plan: [RenderLayerPlanItem]) -> RenderSkipReason? {
        plan.first { $0.layer == layer }?.skipReason
    }
}
