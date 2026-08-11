// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// Resolves how extruded buildings are drawn this frame from the mode, alpha and
/// camera zoom. Single decision point for the pass planner (whether the
/// offscreen building image is needed) and the buildings subsystem (which path
/// and which alpha to draw with): both must see the same path within a frame.
enum BuildingExtrusionPathResolver {
    enum Path: Equatable {
        /// Opaque geometry straight into the world pass.
        case solid
        /// Opaque geometry into the offscreen building image, which the
        /// world pass composites over the map with this alpha.
        case composited(alpha: Float)
    }

    /// True when the composited path runs through the world pass's second
    /// memoryless attachment via framebuffer fetch instead of the offscreen
    /// building-image pass. Every consumer (the pass planner, the buildings,
    /// the flat surface, and the scene models picking pass-compatible
    /// pipelines) must derive the same answer within a frame, so the decision
    /// lives here.
    static func usesInPassBuildingImage(style: ImmersiveMapSettings.StyleSettings,
                                        zoom: Double,
                                        renderSurfaceMode: ViewMode,
                                        supportsFramebufferFetch: Bool) -> Bool {
        guard supportsFramebufferFetch, renderSurfaceMode == .flat else {
            return false
        }
        if case .composited = resolve(style: style, zoom: zoom) {
            return true
        }
        return false
    }

    static func resolve(style: ImmersiveMapSettings.StyleSettings, zoom: Double) -> Path {
        switch style.buildingExtrusionMode {
        case .solid:
            return .solid
        case .translucent:
            return .composited(alpha: style.buildingExtrusionAlpha)
        case .solidAtHighZoom(let startZoom, let endZoom):
            let span = max(endZoom - startZoom, Double.leastNonzeroMagnitude)
            let progress = min(max((zoom - startZoom) / span, 0.0), 1.0)
            // Compositing with alpha 1.0 is visually identical to direct solid
            // rendering, so once the transition finishes we switch to the direct
            // path and stop paying for the offscreen pass, with no visual jump.
            guard progress < 1.0 else {
                return .solid
            }
            let alpha = style.buildingExtrusionAlpha + (1.0 - style.buildingExtrusionAlpha) * Float(progress)
            return .composited(alpha: alpha)
        }
    }
}
