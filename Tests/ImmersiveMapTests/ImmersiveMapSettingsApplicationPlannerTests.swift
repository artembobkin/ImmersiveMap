// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import XCTest

final class ImmersiveMapSettingsApplicationPlannerTests: XCTestCase {
    func testEarthSceneTimeModeChangeIsLiveApplied() {
        let oldSettings = ImmersiveMapSettings.default
        var newSettings = oldSettings
        newSettings.scene.earth.timeMode = .fixed(Date(timeIntervalSince1970: 1_767_225_600))

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        XCTAssertEqual(plan.changedDomains, [.scene])
        XCTAssertEqual(plan.actions, [.liveApply])
        XCTAssertFalse(plan.requiresRendererRecreation)
    }

    func testEarthSceneBrightnessChangeIsLiveApplied() {
        let oldSettings = ImmersiveMapSettings.default
        var newSettings = oldSettings
        newSettings.scene.earth.daySideMinimumBrightness = 0.76

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        XCTAssertEqual(plan.changedDomains, [.scene])
        XCTAssertEqual(plan.actions, [.liveApply])
        XCTAssertFalse(plan.requiresRendererRecreation)
    }

    func testEarthSceneNightLightsIntensityChangeIsLiveApplied() {
        let oldSettings = ImmersiveMapSettings.default
        var newSettings = oldSettings
        newSettings.scene.earth.nightLights.intensity = 0.55

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        XCTAssertEqual(plan.changedDomains, [.scene])
        XCTAssertEqual(plan.actions, [.liveApply])
        XCTAssertFalse(plan.requiresRendererRecreation)
    }

    func testEarthSceneSunSettingsChangeIsLiveApplied() {
        let oldSettings = ImmersiveMapSettings.default
        var newSettings = oldSettings
        newSettings.scene.earth.sun.glowIntensity = 0.25

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        XCTAssertEqual(plan.changedDomains, [.scene])
        XCTAssertEqual(plan.actions, [.liveApply])
        XCTAssertFalse(plan.requiresRendererRecreation)
    }

    func testPostProcessingFXAAChangeIsLiveApplied() {
        let oldSettings = ImmersiveMapSettings.default
        var newSettings = oldSettings
        newSettings.postProcessing.fxaaEnabled = true

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

    func testLabelFallbackPolicyChangeRebuildsPreparedData() {
        let oldSettings = ImmersiveMapSettings.default
        var newSettings = oldSettings
        newSettings.labels.fallbackPolicy = .localFirst

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        XCTAssertEqual(plan.changedDomains, [.labels])
        XCTAssertEqual(plan.actions, [.invalidateCaches, .rebuildPreparedData, .recreateRenderer])
        XCTAssertTrue(plan.requiresRendererRecreation)
    }

    func testMapStyleTokenChangeRebuildsPreparedData() {
        let oldSettings = ImmersiveMapSettings.default
            .tileProvider(MapboxTileProvider(accessToken: "mapbox-token"))
            .mapStyle(MapboxMapStyle(configuration: .mapboxDefault))
        let newSettings = ImmersiveMapSettings.default
            .tileProvider(MapboxTileProvider(accessToken: "mapbox-token"))
            .mapStyle(MapboxMapStyle(configuration: .mapboxDefault.labels { labels in
                labels.district.strokeWidthPx = 1.1
            }))

        let plan = ImmersiveMapSettingsApplicationPlanner.makePlan(from: oldSettings, to: newSettings)

        XCTAssertEqual(plan.changedDomains, [.style])
        XCTAssertEqual(plan.actions, [.invalidateCaches, .rebuildPreparedData, .rebuildGPUResources, .recreateRenderer])
        XCTAssertTrue(plan.requiresRendererRecreation)
    }
}
