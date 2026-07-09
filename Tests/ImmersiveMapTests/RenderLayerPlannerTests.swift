// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class RenderLayerPlannerTests: XCTestCase {
    func testFlatModePlansWorldLayersBeforeEnabledOverlays() {
        let plan = RenderLayerPlanner.plan(
            availability: RenderPassAvailability(renderSurfaceMode: .flat,
                                                 terrainEnabled: true,
                                                 labelsEnabled: true,
                                                 avatarsEnabled: true,
                                                 debugOverlayEnabled: true)
        )

        XCTAssertEqual(plan.map(\.layer), [
            .flatMapSurface,
            .terrain,
            .buildingExtrusion,
            .labels,
            .avatars,
            .debugOverlay
        ])
        XCTAssertTrue(plan.allSatisfy(\.enabled))
        XCTAssertFalse(plan.map(\.layer).contains(.buildingWinner))
    }

    func testFlatModeKeepsOverlayPlanItemsDisabledWhenUnavailable() {
        let plan = RenderLayerPlanner.plan(
            availability: RenderPassAvailability(renderSurfaceMode: .flat,
                                                 terrainEnabled: false,
                                                 labelsEnabled: false,
                                                 avatarsEnabled: false,
                                                 debugOverlayEnabled: false)
        )

        XCTAssertEqual(plan.map(\.layer), [
            .flatMapSurface,
            .terrain,
            .buildingExtrusion,
            .labels,
            .avatars,
            .debugOverlay
        ])
        XCTAssertEqual(enabledLayers(in: plan), [.flatMapSurface, .buildingExtrusion])
        XCTAssertEqual(skipReason(for: .terrain, in: plan), .terrainDisabled)
        XCTAssertEqual(skipReason(for: .labels, in: plan), .noLabelContent)
        XCTAssertEqual(skipReason(for: .avatars, in: plan), .noAvatarContent)
        XCTAssertEqual(skipReason(for: .debugOverlay, in: plan), .debugOverlayDisabled)
    }

    func testGlobeModePlansWorldLayersBeforeEnabledOverlays() {
        let plan = RenderLayerPlanner.plan(
            availability: RenderPassAvailability(renderSurfaceMode: .spherical,
                                                 terrainEnabled: true,
                                                 labelsEnabled: true,
                                                 avatarsEnabled: true,
                                                 debugOverlayEnabled: true)
        )

        XCTAssertEqual(plan.map(\.layer), [
            .starfield,
            .globeSurface,
            .terrain,
            .globeCap,
            .labels,
            .avatars,
            .debugOverlay
        ])
        XCTAssertTrue(plan.allSatisfy(\.enabled))
        XCTAssertFalse(plan.map(\.layer).contains(.buildingWinner))
    }

    func testGlobeModeKeepsOverlayPlanItemsDisabledWhenUnavailable() {
        let plan = RenderLayerPlanner.plan(
            availability: RenderPassAvailability(renderSurfaceMode: .spherical,
                                                 terrainEnabled: false,
                                                 labelsEnabled: false,
                                                 avatarsEnabled: false,
                                                 debugOverlayEnabled: false)
        )

        XCTAssertEqual(plan.map(\.layer), [
            .starfield,
            .globeSurface,
            .terrain,
            .globeCap,
            .labels,
            .avatars,
            .debugOverlay
        ])
        XCTAssertEqual(enabledLayers(in: plan), [.starfield, .globeSurface, .globeCap])
        XCTAssertEqual(skipReason(for: .terrain, in: plan), .terrainDisabled)
        XCTAssertEqual(skipReason(for: .labels, in: plan), .noLabelContent)
        XCTAssertEqual(skipReason(for: .avatars, in: plan), .noAvatarContent)
        XCTAssertEqual(skipReason(for: .debugOverlay, in: plan), .debugOverlayDisabled)
    }

    private func enabledLayers(in plan: [RenderLayerPlanItem]) -> [RenderLayer] {
        plan.filter(\.enabled).map(\.layer)
    }

    private func skipReason(for layer: RenderLayer,
                            in plan: [RenderLayerPlanItem]) -> RenderSkipReason? {
        plan.first { $0.layer == layer }?.skipReason
    }
}
