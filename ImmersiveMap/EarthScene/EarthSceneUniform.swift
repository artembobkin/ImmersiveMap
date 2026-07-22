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
    var sunVisualEnabled: UInt32
    var sunDiskAngularSize: Float
    var sunDiskIntensity: Float
    var sunGlowIntensity: Float
    var sunEdgeGlareIntensity: Float
    var sunLimbHaloIntensity: Float
    var sunLimbHaloWidth: Float
    var sunShadowFade: Float
    var _padding0: UInt32

    static let minimumFadeWidth: Float = 0.001

    /// Зум, на котором тень от солнца (терминатор день/ночь) ещё полностью видна.
    static let sunShadowFadeStartZoom: Double = 1.0

    /// Зум, на котором тень от солнца полностью исчезает.
    static let sunShadowFadeEndZoom: Double = 2.0

    static let disabled = EarthSceneUniform(
        sunDirection: SIMD3<Float>(0, 0, 1),
        isEnabled: 0,
        daySideMinimumBrightness: 0,
        nightSideBrightness: 0,
        terminatorFadeWidth: minimumFadeWidth,
        sunVisualEnabled: 0,
        sunDiskAngularSize: minimumFadeWidth,
        sunDiskIntensity: 0,
        sunGlowIntensity: 0,
        sunEdgeGlareIntensity: 0,
        sunLimbHaloIntensity: 0,
        sunLimbHaloWidth: minimumFadeWidth,
        sunShadowFade: 0,
        _padding0: 0
    )

    init(settings: ImmersiveMapSettings.EarthSceneSettings,
         now: Date = Date(),
         zoom: Double = sunShadowFadeStartZoom) {
        guard settings.isEnabled else {
            self = Self.disabled
            return
        }

        let date = settings.timeMode.resolvedDate(now: now)
        let sun = settings.sun
        let sunVisualEnabled: UInt32 = sun.isEnabled ? 1 : 0

        self.init(
            sunDirection: EarthSceneSunCalculator.earthFixedSunDirection(at: date),
            isEnabled: 1,
            daySideMinimumBrightness: Self.clampedUnit(settings.daySideMinimumBrightness),
            nightSideBrightness: Self.clampedUnit(settings.nightSideBrightness),
            terminatorFadeWidth: Self.resolvedFadeWidth(settings.terminatorFadeWidth),
            sunVisualEnabled: sunVisualEnabled,
            sunDiskAngularSize: Self.resolvedFadeWidth(sun.diskAngularSize),
            sunDiskIntensity: sun.isEnabled ? Self.clampedUnit(sun.diskIntensity) : 0,
            sunGlowIntensity: sun.isEnabled ? Self.clampedUnit(sun.glowIntensity) : 0,
            sunEdgeGlareIntensity: sun.isEnabled ? Self.clampedUnit(sun.edgeGlareIntensity) : 0,
            sunLimbHaloIntensity: sun.isEnabled ? Self.clampedUnit(sun.limbHaloIntensity) : 0,
            sunLimbHaloWidth: Self.resolvedFadeWidth(sun.limbHaloWidth),
            sunShadowFade: Self.sunShadowFade(zoom: zoom),
            _padding0: 0
        )
    }

    private init(sunDirection: SIMD3<Float>,
                 isEnabled: UInt32,
                 daySideMinimumBrightness: Float,
                 nightSideBrightness: Float,
                 terminatorFadeWidth: Float,
                 sunVisualEnabled: UInt32,
                 sunDiskAngularSize: Float,
                 sunDiskIntensity: Float,
                 sunGlowIntensity: Float,
                 sunEdgeGlareIntensity: Float,
                 sunLimbHaloIntensity: Float,
                 sunLimbHaloWidth: Float,
                 sunShadowFade: Float,
                 _padding0: UInt32) {
        self.sunDirection = sunDirection
        self.isEnabled = isEnabled
        self.daySideMinimumBrightness = daySideMinimumBrightness
        self.nightSideBrightness = nightSideBrightness
        self.terminatorFadeWidth = terminatorFadeWidth
        self.sunVisualEnabled = sunVisualEnabled
        self.sunDiskAngularSize = sunDiskAngularSize
        self.sunDiskIntensity = sunDiskIntensity
        self.sunGlowIntensity = sunGlowIntensity
        self.sunEdgeGlareIntensity = sunEdgeGlareIntensity
        self.sunLimbHaloIntensity = sunLimbHaloIntensity
        self.sunLimbHaloWidth = sunLimbHaloWidth
        self.sunShadowFade = sunShadowFade
        self._padding0 = _padding0
    }

    /// Доля исчезновения тени от солнца по зуму: 0 - тень видна полностью,
    /// 1 - тени нет. Плавно нарастает по smoothstep между стартовым и конечным зумом.
    private static func sunShadowFade(zoom: Double) -> Float {
        let start = sunShadowFadeStartZoom
        let end = sunShadowFadeEndZoom
        guard zoom.isFinite, end > start else {
            return zoom >= end ? 1 : 0
        }

        let t = min(max((zoom - start) / (end - start), 0), 1)
        return Float(t * t * (3 - 2 * t))
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
