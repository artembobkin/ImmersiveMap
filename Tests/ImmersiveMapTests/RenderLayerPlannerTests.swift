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
                                                 starfieldEnabled: true,
                                                 atmosphereEnabled: true)
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
                                                 starfieldEnabled: true,
                                                 atmosphereEnabled: true)
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
                                                 starfieldEnabled: true,
                                                 atmosphereEnabled: true)
        )

        XCTAssertEqual(plan.map(\.layer), [
            .globeSurface,
            .globeVectorSurface,
            .globeSurfaceLighting,
            .starfield,
            .atmosphere,
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
                                                 starfieldEnabled: true,
                                                 atmosphereEnabled: true)
        )

        XCTAssertEqual(plan.map(\.layer), [
            .globeSurface,
            .globeVectorSurface,
            .globeSurfaceLighting,
            .starfield,
            .atmosphere,
            .globeCap,
            .sceneModels,
            .routes,
            .sceneModelOcclusion,
            .labels,
            .avatars,
            .debugOverlay
        ])
        XCTAssertEqual(enabledLayers(in: plan), [.globeSurface, .globeVectorSurface, .globeSurfaceLighting, .starfield, .atmosphere, .globeCap, .sceneModels, .routes])
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
                                                 starfieldEnabled: true,
                                                 atmosphereEnabled: true)
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
                                                 starfieldEnabled: true,
                                                 atmosphereEnabled: true)
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
                                                 starfieldEnabled: false,
                                                 atmosphereEnabled: false)
        )

        XCTAssertEqual(enabledLayers(in: plan), [
            .globeSurface,
            .globeVectorSurface,
            .globeSurfaceLighting,
            .globeCap,
            .sceneModels,
            .routes,
            .sceneModelOcclusion,
            .labels,
            .avatars,
            .debugOverlay
        ])
        XCTAssertEqual(skipReason(for: .starfield, in: plan), .transparentSpace)
        // The halo is painted in space, so it goes with the starfield and
        // reports the same reason: nothing outside the globe is painted.
        XCTAssertEqual(skipReason(for: .atmosphere, in: plan), .transparentSpace)
    }

    /// The atmosphere halo draws after the surface and the starfield,
    /// depth-tested at the far plane. Off by setting, it stays in the plan
    /// disabled with its own reason, and the starfield is untouched.
    func testAtmosphereOffBySettingKeepsTheStarfield() {
        let plan = RenderLayerPlanner.plan(
            availability: RenderPassAvailability(renderSurfaceMode: .spherical,
                                                 labelsEnabled: false,
                                                 avatarsEnabled: false,
                                                 debugOverlayEnabled: false,
                                                 sceneModelOcclusionEnabled: false,
                                                 starfieldEnabled: true,
                                                 atmosphereEnabled: false)
        )

        XCTAssertEqual(enabledLayers(in: plan), [.globeSurface, .globeVectorSurface, .globeSurfaceLighting, .starfield, .globeCap, .sceneModels, .routes])
        XCTAssertEqual(skipReason(for: .atmosphere, in: plan), .atmosphereDisabled)
        XCTAssertNil(skipReason(for: .starfield, in: plan))
    }

    /// The halo is a world layer of the globe presentation only: the flat map
    /// has no sphere to wrap it around, and it never runs in the overlay pass.
    func testAtmosphereIsAGlobeWorldLayer() {
        XCTAssertTrue(RenderPassGraph.isWorldLayer(.atmosphere))
        XCTAssertFalse(RenderPassGraph.isOverlayLayer(.atmosphere))

        let flatPlan = RenderLayerPlanner.plan(
            availability: RenderPassAvailability(renderSurfaceMode: .flat,
                                                 labelsEnabled: false,
                                                 avatarsEnabled: false,
                                                 debugOverlayEnabled: false,
                                                 sceneModelOcclusionEnabled: false,
                                                 starfieldEnabled: true,
                                                 atmosphereEnabled: true)
        )
        XCTAssertFalse(flatPlan.map(\.layer).contains(.atmosphere))
    }

    private func enabledLayers(in plan: [RenderLayerPlanItem]) -> [RenderLayer] {
        plan.filter(\.enabled).map(\.layer)
    }

    private func skipReason(for layer: RenderLayer,
                            in plan: [RenderLayerPlanItem]) -> RenderSkipReason? {
        plan.first { $0.layer == layer }?.skipReason
    }
}
