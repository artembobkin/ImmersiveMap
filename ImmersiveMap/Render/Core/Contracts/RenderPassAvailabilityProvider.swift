// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

protocol RenderPassAvailabilityProvider: AnyObject {
    func contributePassAvailability(settings: ImmersiveMapSettings,
                                    builder: inout RenderPassAvailabilityBuilder)
}

struct RenderPassAvailabilityBuilder {
    let renderSurfaceMode: ViewMode

    var labelsEnabled: Bool = false
    var avatarsEnabled: Bool = false
    var debugOverlayEnabled: Bool = false
    var sceneModelOcclusionEnabled: Bool = false
    /// Unlike the content-driven flags above, the starfield is on by default and
    /// is turned off by settings, so it starts enabled instead of accumulating.
    var starfieldEnabled: Bool = true
    /// On by default like the starfield: the atmosphere halo is part of the
    /// globe look and is turned off by settings (or by transparent space).
    var atmosphereEnabled: Bool = true

    func build() -> RenderPassAvailability {
        RenderPassAvailability(renderSurfaceMode: renderSurfaceMode,
                               labelsEnabled: labelsEnabled,
                               avatarsEnabled: avatarsEnabled,
                               debugOverlayEnabled: debugOverlayEnabled,
                               sceneModelOcclusionEnabled: sceneModelOcclusionEnabled,
                               starfieldEnabled: starfieldEnabled,
                               atmosphereEnabled: atmosphereEnabled)
    }
}
