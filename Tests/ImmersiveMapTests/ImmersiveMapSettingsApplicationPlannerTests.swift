// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class ImmersiveMapSettingsApplicationPlannerTests: XCTestCase {


    func testSceneLightDirectionChangeIsLiveApplied() {
        let oldSettings = ImmersiveMapSettings.default
        let newSettings = oldSettings.sceneLight(direction: SIMD3<Float>(0.5, -0.3, 1.0))

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        XCTAssertEqual(plan.changedDomains, [.scene])
        XCTAssertEqual(plan.actions, [.liveApply])
        XCTAssertFalse(plan.requiresRendererRecreation)
    }

    func testShadowSettingsChangeIsLiveApplied() {
        let oldSettings = ImmersiveMapSettings.default
        var newSettings = oldSettings.shadows(isEnabled: false)
        newSettings.scene.shadows.mapResolution = 512

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        XCTAssertEqual(plan.changedDomains, [.scene])
        XCTAssertEqual(plan.actions, [.liveApply])
        XCTAssertFalse(plan.requiresRendererRecreation)
    }

    /// The atmosphere is a per-frame uniform: switching it, or recolouring
    /// it, must not recreate the renderer.
    func testAtmosphereSettingsChangeIsLiveApplied() {
        let oldSettings = ImmersiveMapSettings.default
        var newSettings = oldSettings.atmosphere(isEnabled: false)
        newSettings.scene.atmosphere.color = SIMD3<Float>(1, 0.8, 0.6)

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        XCTAssertEqual(plan.changedDomains, [.scene])
        XCTAssertEqual(plan.actions, [.liveApply])
        XCTAssertFalse(plan.requiresRendererRecreation)
    }

    func testPostProcessingFXAAChangeIsLiveApplied() {
        let oldSettings = ImmersiveMapSettings.default
        let newSettings = oldSettings.fxaa(isEnabled: true)

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        XCTAssertEqual(plan.changedDomains, [.postProcessing])
        XCTAssertEqual(plan.actions, [.liveApply])
        XCTAssertFalse(plan.requiresRendererRecreation)
    }

    func testDebugPanelEnabledChangeRecreatesRendererForTileStatusInstrumentation() {
        let oldSettings = ImmersiveMapSettings.default
        let newSettings = oldSettings.debugPanel()

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        XCTAssertEqual(plan.changedDomains, [.debug])
        XCTAssertEqual(plan.actions, [.recreateRenderer])
        XCTAssertTrue(plan.requiresRendererRecreation)
    }

    func testChangingOnlyTheDeprecatedMemoryCacheSizeYieldsNoActions() {
        let oldSettings = ImmersiveMapSettings.default
        var newSettings = oldSettings
        newSettings.tiles.cache.legacyMemoryCacheSizeInBytes += 1

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        // The field is deprecated and ignored; a difference in it must not
        // recreate the renderer or invalidate any cache.
        XCTAssertTrue(plan.changedDomains.isEmpty)
        XCTAssertTrue(plan.actions.isEmpty)
        XCTAssertFalse(plan.requiresRendererRecreation)
    }

    func testLabelFallbackPolicyChangeRebuildsPreparedData() {
        let oldSettings = ImmersiveMapSettings.default
        var newSettings = oldSettings
        newSettings.labels.fallbackPolicy = .localFirst

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        XCTAssertEqual(plan.changedDomains, [.labels])
        XCTAssertEqual(plan.actions, [.invalidateCaches, .rebuildPreparedData, .recreateRenderer])
        XCTAssertTrue(plan.requiresRendererRecreation)
    }

    func testBuildingExtrusionModeChangeIsLiveApplied() {
        let oldSettings = ImmersiveMapSettings.default
        let newSettings = oldSettings.buildingExtrusionMode(.translucent)

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        XCTAssertEqual(plan.changedDomains, [.style])
        XCTAssertEqual(plan.actions, [.liveApply])
        XCTAssertFalse(plan.requiresRendererRecreation)
    }

    func testBuildingExtrusionZoomTransitionRangeChangeIsLiveApplied() {
        let oldSettings = ImmersiveMapSettings.default.buildingExtrusionMode(.solidAtHighZoom)
        let newSettings = oldSettings.buildingExtrusionMode(.solidAtHighZoom(startZoom: 16.0, endZoom: 17.5))

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        XCTAssertEqual(plan.changedDomains, [.style])
        XCTAssertEqual(plan.actions, [.liveApply])
        XCTAssertFalse(plan.requiresRendererRecreation)
    }

    func testBuildingExtrusionAlphaChangeIsLiveApplied() {
        let oldSettings = ImmersiveMapSettings.default
        var newSettings = oldSettings
        newSettings.style.buildingExtrusionAlpha = 0.85

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        XCTAssertEqual(plan.changedDomains, [.style])
        XCTAssertEqual(plan.actions, [.liveApply])
        XCTAssertFalse(plan.requiresRendererRecreation)
    }

    func testBuildingExtrusionModeChangeCombinedWithBaseColorsChangeRecreatesRenderer() {
        let oldSettings = ImmersiveMapSettings.default
        var newSettings = oldSettings.buildingExtrusionMode(.translucent)
        newSettings.style.baseColors.water = SIMD4<Float>(0.1, 0.2, 0.8, 1.0)

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        XCTAssertEqual(plan.changedDomains, [.style])
        XCTAssertEqual(plan.actions, [.invalidateCaches, .rebuildPreparedData, .rebuildGPUResources, .recreateRenderer])
        XCTAssertTrue(plan.requiresRendererRecreation)
    }

    func testMapStyleLabelPaletteChangeRebuildsPreparedData() {
        let oldSettings = ImmersiveMapSettings.default
            .mapStyle(ImmersiveMapTilesMapStyle(configuration: .immersiveMapTilesDefault))
        let newSettings = ImmersiveMapSettings.default
            .mapStyle(ImmersiveMapTilesMapStyle(configuration: .immersiveMapTilesDefault.labels { labels in
                labels.town.haloEm = 0.11
            }))

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        XCTAssertEqual(plan.changedDomains, [.style])
        XCTAssertEqual(plan.actions, [.invalidateCaches, .rebuildPreparedData, .rebuildGPUResources, .recreateRenderer])
        XCTAssertTrue(plan.requiresRendererRecreation)
    }

    func testOfflineTileModeChangeRecreatesTheRendererWithoutInvalidatingCaches() {
        let oldSettings = ImmersiveMapSettings.default
        let newSettings = oldSettings.offlineTileMode(.offlineOnly)

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        XCTAssertEqual(plan.changedDomains, [.tiles])
        // The bytes come from the same tile source either way, so the caches
        // stay valid; only the pipeline's transports need rebuilding.
        XCTAssertEqual(plan.actions, [.recreateRenderer])
        XCTAssertTrue(plan.requiresRendererRecreation)
    }
}
