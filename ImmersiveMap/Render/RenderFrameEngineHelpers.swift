// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import Metal
import QuartzCore

enum RenderFrameStageMeasurer {
    static func measure(_ stage: FrameStage,
                        diagnostics: FrameDiagnostics,
                        block: () -> Void) {
        let start = CACurrentMediaTime()
        block()
        diagnostics.recordStage(stage, duration: CACurrentMediaTime() - start)
    }
}

enum RenderDebugOverlayPolicy {
    static func shouldEncode(_ settings: ImmersiveMapSettings.DebugSettings,
                             controls: DebugOverlayControlSnapshot) -> Bool {
        guard settings.enableDebugPanel else {
            return false
        }
        guard controls.axesEnabled
            || controls.tileLayersEnabled
            || controls.roadLabelTilesEnabled
            || controls.baseLabelBoundsEnabled
            || controls.roadLabelBoundsEnabled else {
            return false
        }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}

enum RenderFrameClearColor {
    static func make(transition: Float,
                     settings: ImmersiveMapSettings) -> MTLClearColor {
        let transitionMix = Double(transition)
        let mapColor = settings.scene.mapClearColor
        // Transparent space clears to a fully transparent pixel and reaches the
        // map color through premultiplied values: the drawable is composited by
        // the window server as premultiplied alpha, so a non-zero color at zero
        // alpha would tint the app's own background.
        let spaceColor = settings.scene.space.isTransparent
            ? SIMD4<Double>(repeating: 0.0)
            : settings.scene.space.clearColor
        let targetColor = settings.scene.space.isTransparent
            ? SIMD4<Double>(mapColor.x * mapColor.w,
                            mapColor.y * mapColor.w,
                            mapColor.z * mapColor.w,
                            mapColor.w)
            : mapColor
        let clearColorValue = spaceColor + (targetColor - spaceColor) * transitionMix

        return MTLClearColor(red: clearColorValue.x,
                             green: clearColorValue.y,
                             blue: clearColorValue.z,
                             alpha: clearColorValue.w)
    }
}
