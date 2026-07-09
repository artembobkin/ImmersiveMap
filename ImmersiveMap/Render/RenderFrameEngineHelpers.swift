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
        guard controls.axesEnabled || controls.tileLayersEnabled || controls.roadLabelTilesEnabled else {
            return false
        }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }
}

enum RenderTerrainAvailabilityPolicy {
    static func shouldRender(settings: ImmersiveMapSettings,
                             controls: DebugOverlayControlSnapshot) -> Bool {
        settings.terrain.isEnabled && settings.terrain.source != nil && controls.terrainEnabled
    }
}

enum RenderFrameClearColor {
    static func make(transition: Float,
                     settings: ImmersiveMapSettings) -> MTLClearColor {
        let transitionMix = Double(transition)
        let spaceColor = settings.scene.space.clearColor
        let mapColor = settings.scene.mapClearColor
        let clearColorValue = spaceColor + (mapColor - spaceColor) * transitionMix

        return MTLClearColor(red: clearColorValue.x,
                             green: clearColorValue.y,
                             blue: clearColorValue.z,
                             alpha: clearColorValue.w)
    }
}
