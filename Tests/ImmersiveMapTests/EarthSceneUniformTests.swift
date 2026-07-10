// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

@testable import ImmersiveMap
import simd
import XCTest

final class EarthSceneUniformTests: XCTestCase {
    func testDisabledUniformDisablesEarthSceneAndNightLights() {
        let uniform = EarthSceneUniform.disabled

        XCTAssertEqual(uniform.isEnabled, 0)
        XCTAssertEqual(uniform.nightLightsEnabled, 0)
        XCTAssertEqual(uniform.sunVisualEnabled, 0)
        XCTAssertEqual(uniform.sunDiskIntensity, 0.0, accuracy: 0.0001)
        XCTAssertEqual(uniform.sunGlowIntensity, 0.0, accuracy: 0.0001)
        XCTAssertEqual(uniform.sunEdgeGlareIntensity, 0.0, accuracy: 0.0001)
        XCTAssertEqual(uniform.sunLimbHaloIntensity, 0.0, accuracy: 0.0001)
        XCTAssertEqual(uniform.sunDiskAngularSize, EarthSceneUniform.minimumFadeWidth, accuracy: 0.0001)
        XCTAssertEqual(uniform.sunLimbHaloWidth, EarthSceneUniform.minimumFadeWidth, accuracy: 0.0001)
    }

    func testDisabledEarthSceneSettingsDisableSunTerminatorAndNightLightsPackage() {
        let settings = ImmersiveMapSettings.EarthSceneSettings(
            isEnabled: false,
            daySideMinimumBrightness: 1.0,
            nightSideBrightness: 1.0,
            nightLights: .init(isEnabled: true, intensity: 1.0),
            sun: .init(
                isEnabled: true,
                diskIntensity: 1.0,
                glowIntensity: 1.0,
                edgeGlareIntensity: 1.0,
                limbHaloIntensity: 1.0
            )
        )

        let uniform = EarthSceneUniform(settings: settings, now: .distantPast)

        XCTAssertEqual(uniform.isEnabled, 0)
        XCTAssertEqual(uniform.nightLightsEnabled, 0)
        XCTAssertEqual(uniform.sunVisualEnabled, 0)
        XCTAssertEqual(uniform.daySideMinimumBrightness, 0.0, accuracy: 0.0001)
        XCTAssertEqual(uniform.nightSideBrightness, 0.0, accuracy: 0.0001)
        XCTAssertEqual(uniform.nightLightsIntensity, 0.0, accuracy: 0.0001)
        XCTAssertEqual(uniform.sunDiskIntensity, 0.0, accuracy: 0.0001)
        XCTAssertEqual(uniform.sunGlowIntensity, 0.0, accuracy: 0.0001)
        XCTAssertEqual(uniform.sunEdgeGlareIntensity, 0.0, accuracy: 0.0001)
        XCTAssertEqual(uniform.sunLimbHaloIntensity, 0.0, accuracy: 0.0001)
    }

    func testEnabledFixedDateSettingsProduceExpectedSunDirection() throws {
        let date = try Date.utc(year: 2026, month: 6, day: 9, hour: 9, minute: 30, second: 0)
        let settings = ImmersiveMapSettings.EarthSceneSettings(
            timeMode: .fixed(date),
            nightLights: .init(isEnabled: true)
        )

        let uniform = EarthSceneUniform(settings: settings, now: .distantPast)
        let expectedDirection = EarthSceneSunCalculator.earthFixedSunDirection(at: date)

        XCTAssertEqual(uniform.isEnabled, 1)
        XCTAssertEqual(uniform.nightLightsEnabled, 1)
        XCTAssertEqual(uniform.sunDirection.x, expectedDirection.x, accuracy: 0.0001)
        XCTAssertEqual(uniform.sunDirection.y, expectedDirection.y, accuracy: 0.0001)
        XCTAssertEqual(uniform.sunDirection.z, expectedDirection.z, accuracy: 0.0001)
        XCTAssertEqual(simd_length(uniform.sunDirection), 1.0, accuracy: 0.0001)
        XCTAssertEqual(uniform.sunEdgeGlareIntensity, 0.0, accuracy: 0.0001)
    }

    func testShaderFacingFloatValuesAreClampedAndResolvedSafely() {
        let settings = ImmersiveMapSettings.EarthSceneSettings(
            daySideMinimumBrightness: -0.25,
            nightSideBrightness: 1.75,
            terminatorFadeWidth: -3.0,
            nightLights: .init(
                intensity: 2.5,
                terminatorFadeWidth: 0.0
            ),
            sun: .init(
                diskAngularSize: .nan,
                diskIntensity: -0.3,
                glowIntensity: 1.8,
                edgeGlareIntensity: .infinity,
                limbHaloIntensity: 0.4,
                limbHaloWidth: -0.2
            )
        )

        let uniform = EarthSceneUniform(settings: settings, now: .distantPast)

        XCTAssertEqual(uniform.daySideMinimumBrightness, 0.0, accuracy: 0.0001)
        XCTAssertEqual(uniform.nightSideBrightness, 1.0, accuracy: 0.0001)
        XCTAssertEqual(uniform.terminatorFadeWidth, EarthSceneUniform.minimumFadeWidth, accuracy: 0.0001)
        XCTAssertEqual(uniform.nightLightsIntensity, 1.0, accuracy: 0.0001)
        XCTAssertEqual(uniform.nightLightsTerminatorFadeWidth, EarthSceneUniform.minimumFadeWidth, accuracy: 0.0001)
        XCTAssertEqual(uniform.sunVisualEnabled, 1)
        XCTAssertEqual(uniform.sunDiskAngularSize, EarthSceneUniform.minimumFadeWidth, accuracy: 0.0001)
        XCTAssertEqual(uniform.sunDiskIntensity, 0.0, accuracy: 0.0001)
        XCTAssertEqual(uniform.sunGlowIntensity, 1.0, accuracy: 0.0001)
        XCTAssertEqual(uniform.sunEdgeGlareIntensity, 0.0, accuracy: 0.0001)
        XCTAssertEqual(uniform.sunLimbHaloIntensity, 0.4, accuracy: 0.0001)
        XCTAssertEqual(uniform.sunLimbHaloWidth, EarthSceneUniform.minimumFadeWidth, accuracy: 0.0001)
    }

    func testDisabledSunVisualKeepsSceneEnabledAndZeroesSunIntensities() {
        let settings = ImmersiveMapSettings.EarthSceneSettings(
            sun: .init(
                isEnabled: false,
                diskAngularSize: 0.2,
                diskIntensity: 1.0,
                glowIntensity: 0.8,
                edgeGlareIntensity: 0.6,
                limbHaloIntensity: 0.4,
                limbHaloWidth: 0.3
            )
        )

        let uniform = EarthSceneUniform(settings: settings, now: .distantPast)

        XCTAssertEqual(uniform.isEnabled, 1)
        XCTAssertEqual(uniform.sunVisualEnabled, 0)
        XCTAssertEqual(uniform.sunDiskAngularSize, 0.2, accuracy: 0.0001)
        XCTAssertEqual(uniform.sunDiskIntensity, 0.0, accuracy: 0.0001)
        XCTAssertEqual(uniform.sunGlowIntensity, 0.0, accuracy: 0.0001)
        XCTAssertEqual(uniform.sunEdgeGlareIntensity, 0.0, accuracy: 0.0001)
        XCTAssertEqual(uniform.sunLimbHaloIntensity, 0.0, accuracy: 0.0001)
        XCTAssertEqual(uniform.sunLimbHaloWidth, 0.3, accuracy: 0.0001)
    }

    func testRealtimeTimeModeUsesInjectedNowForSunDirection() throws {
        let now = try Date.utc(year: 2026, month: 12, day: 21, hour: 7, minute: 15, second: 0)
        let settings = ImmersiveMapSettings.EarthSceneSettings(timeMode: .realtime)

        let uniform = EarthSceneUniform(settings: settings, now: now)
        let expectedDirection = EarthSceneSunCalculator.earthFixedSunDirection(at: now)

        XCTAssertEqual(uniform.sunDirection.x, expectedDirection.x, accuracy: 0.0001)
        XCTAssertEqual(uniform.sunDirection.y, expectedDirection.y, accuracy: 0.0001)
        XCTAssertEqual(uniform.sunDirection.z, expectedDirection.z, accuracy: 0.0001)
    }

    func testSunShadowFadeProgressesFromZoomOneToTwo() {
        let settings = ImmersiveMapSettings.EarthSceneSettings()

        let below = EarthSceneUniform(settings: settings, now: .distantPast, zoom: 0.5)
        let start = EarthSceneUniform(settings: settings, now: .distantPast, zoom: 1.0)
        let middle = EarthSceneUniform(settings: settings, now: .distantPast, zoom: 1.5)
        let end = EarthSceneUniform(settings: settings, now: .distantPast, zoom: 2.0)
        let above = EarthSceneUniform(settings: settings, now: .distantPast, zoom: 3.0)

        XCTAssertEqual(below.sunShadowFade, 0.0, accuracy: 0.0001)
        XCTAssertEqual(start.sunShadowFade, 0.0, accuracy: 0.0001)
        XCTAssertEqual(middle.sunShadowFade, 0.5, accuracy: 0.0001)
        XCTAssertEqual(end.sunShadowFade, 1.0, accuracy: 0.0001)
        XCTAssertEqual(above.sunShadowFade, 1.0, accuracy: 0.0001)
        XCTAssertGreaterThan(middle.sunShadowFade, start.sunShadowFade)
        XCTAssertGreaterThan(end.sunShadowFade, middle.sunShadowFade)
    }

    func testUniformMatchesShaderABIRelatedLayout() {
        XCTAssertEqual(MemoryLayout<EarthSceneUniform>.stride, 80)
        XCTAssertEqual(MemoryLayout<EarthSceneUniform>.alignment, 16)
        XCTAssertEqual(MemoryLayout<EarthSceneUniform>.offset(of: \.sunDirection), 0)
        XCTAssertEqual(MemoryLayout<EarthSceneUniform>.offset(of: \.isEnabled), 16)
        XCTAssertEqual(MemoryLayout<EarthSceneUniform>.offset(of: \.daySideMinimumBrightness), 20)
        XCTAssertEqual(MemoryLayout<EarthSceneUniform>.offset(of: \.nightSideBrightness), 24)
        XCTAssertEqual(MemoryLayout<EarthSceneUniform>.offset(of: \.terminatorFadeWidth), 28)
        XCTAssertEqual(MemoryLayout<EarthSceneUniform>.offset(of: \.nightLightsIntensity), 32)
        XCTAssertEqual(MemoryLayout<EarthSceneUniform>.offset(of: \.nightLightsTerminatorFadeWidth), 36)
        XCTAssertEqual(MemoryLayout<EarthSceneUniform>.offset(of: \.nightLightsEnabled), 40)
        XCTAssertEqual(MemoryLayout<EarthSceneUniform>.offset(of: \.sunVisualEnabled), 44)
        XCTAssertEqual(MemoryLayout<EarthSceneUniform>.offset(of: \.sunDiskAngularSize), 48)
        XCTAssertEqual(MemoryLayout<EarthSceneUniform>.offset(of: \.sunDiskIntensity), 52)
        XCTAssertEqual(MemoryLayout<EarthSceneUniform>.offset(of: \.sunGlowIntensity), 56)
        XCTAssertEqual(MemoryLayout<EarthSceneUniform>.offset(of: \.sunEdgeGlareIntensity), 60)
        XCTAssertEqual(MemoryLayout<EarthSceneUniform>.offset(of: \.sunLimbHaloIntensity), 64)
        XCTAssertEqual(MemoryLayout<EarthSceneUniform>.offset(of: \.sunLimbHaloWidth), 68)
        XCTAssertEqual(MemoryLayout<EarthSceneUniform>.offset(of: \.sunShadowFade), 72)
        XCTAssertEqual(MemoryLayout<EarthSceneUniform>.offset(of: \._padding0), 76)
    }
}

private extension Date {
    static func utc(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int) throws -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return try XCTUnwrap(components.date)
    }
}
