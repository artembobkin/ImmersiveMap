// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Foundation
import simd

struct EarthSceneUniform {
    var sunDirection: SIMD3<Float>
    var isEnabled: UInt32
    var daySideMinimumBrightness: Float
    var nightSideBrightness: Float
    var terminatorFadeWidth: Float
    var nightLightsIntensity: Float
    var nightLightsTerminatorFadeWidth: Float
    var nightLightsEnabled: UInt32
    var sunVisualEnabled: UInt32
    var sunDiskAngularSize: Float
    var sunDiskIntensity: Float
    var sunGlowIntensity: Float
    var sunEdgeGlareIntensity: Float
    var sunLimbHaloIntensity: Float
    var sunLimbHaloWidth: Float
    var _padding0: SIMD2<UInt32>

    static let minimumFadeWidth: Float = 0.001

    static let disabled = EarthSceneUniform(
        sunDirection: SIMD3<Float>(0, 0, 1),
        isEnabled: 0,
        daySideMinimumBrightness: 0,
        nightSideBrightness: 0,
        terminatorFadeWidth: minimumFadeWidth,
        nightLightsIntensity: 0,
        nightLightsTerminatorFadeWidth: minimumFadeWidth,
        nightLightsEnabled: 0,
        sunVisualEnabled: 0,
        sunDiskAngularSize: minimumFadeWidth,
        sunDiskIntensity: 0,
        sunGlowIntensity: 0,
        sunEdgeGlareIntensity: 0,
        sunLimbHaloIntensity: 0,
        sunLimbHaloWidth: minimumFadeWidth,
        _padding0: SIMD2<UInt32>(repeating: 0)
    )

    init(settings: ImmersiveMapSettings.EarthSceneSettings, now: Date = Date()) {
        guard settings.isEnabled else {
            self = Self.disabled
            return
        }

        let date = settings.timeMode.resolvedDate(now: now)
        let nightLights = settings.nightLights
        let sun = settings.sun
        let sunVisualEnabled: UInt32 = sun.isEnabled ? 1 : 0

        self.init(
            sunDirection: EarthSceneSunCalculator.earthFixedSunDirection(at: date),
            isEnabled: 1,
            daySideMinimumBrightness: Self.clampedUnit(settings.daySideMinimumBrightness),
            nightSideBrightness: Self.clampedUnit(settings.nightSideBrightness),
            terminatorFadeWidth: Self.resolvedFadeWidth(settings.terminatorFadeWidth),
            nightLightsIntensity: Self.clampedUnit(nightLights.intensity),
            nightLightsTerminatorFadeWidth: Self.resolvedFadeWidth(nightLights.terminatorFadeWidth),
            nightLightsEnabled: nightLights.isEnabled ? 1 : 0,
            sunVisualEnabled: sunVisualEnabled,
            sunDiskAngularSize: Self.resolvedFadeWidth(sun.diskAngularSize),
            sunDiskIntensity: sun.isEnabled ? Self.clampedUnit(sun.diskIntensity) : 0,
            sunGlowIntensity: sun.isEnabled ? Self.clampedUnit(sun.glowIntensity) : 0,
            sunEdgeGlareIntensity: sun.isEnabled ? Self.clampedUnit(sun.edgeGlareIntensity) : 0,
            sunLimbHaloIntensity: sun.isEnabled ? Self.clampedUnit(sun.limbHaloIntensity) : 0,
            sunLimbHaloWidth: Self.resolvedFadeWidth(sun.limbHaloWidth),
            _padding0: SIMD2<UInt32>(repeating: 0)
        )
    }

    private init(sunDirection: SIMD3<Float>,
                 isEnabled: UInt32,
                 daySideMinimumBrightness: Float,
                 nightSideBrightness: Float,
                 terminatorFadeWidth: Float,
                 nightLightsIntensity: Float,
                 nightLightsTerminatorFadeWidth: Float,
                 nightLightsEnabled: UInt32,
                 sunVisualEnabled: UInt32,
                 sunDiskAngularSize: Float,
                 sunDiskIntensity: Float,
                 sunGlowIntensity: Float,
                 sunEdgeGlareIntensity: Float,
                 sunLimbHaloIntensity: Float,
                 sunLimbHaloWidth: Float,
                 _padding0: SIMD2<UInt32>) {
        self.sunDirection = sunDirection
        self.isEnabled = isEnabled
        self.daySideMinimumBrightness = daySideMinimumBrightness
        self.nightSideBrightness = nightSideBrightness
        self.terminatorFadeWidth = terminatorFadeWidth
        self.nightLightsIntensity = nightLightsIntensity
        self.nightLightsTerminatorFadeWidth = nightLightsTerminatorFadeWidth
        self.nightLightsEnabled = nightLightsEnabled
        self.sunVisualEnabled = sunVisualEnabled
        self.sunDiskAngularSize = sunDiskAngularSize
        self.sunDiskIntensity = sunDiskIntensity
        self.sunGlowIntensity = sunGlowIntensity
        self.sunEdgeGlareIntensity = sunEdgeGlareIntensity
        self.sunLimbHaloIntensity = sunLimbHaloIntensity
        self.sunLimbHaloWidth = sunLimbHaloWidth
        self._padding0 = _padding0
    }

    private static func clampedUnit(_ value: Float) -> Float {
        guard value.isFinite else {
            return 0
        }

        return min(max(value, 0), 1)
    }

    private static func resolvedFadeWidth(_ value: Float) -> Float {
        guard value.isFinite else {
            return minimumFadeWidth
        }

        return max(value, minimumFadeWidth)
    }
}
