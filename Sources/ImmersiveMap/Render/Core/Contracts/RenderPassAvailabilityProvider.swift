// Copyright (c) 2025-2026 Artem Bobkin.
// SPDX-License-Identifier: MIT

protocol RenderPassAvailabilityProvider: AnyObject {
    func contributePassAvailability(settings: ImmersiveMapSettings,
                                    builder: inout RenderPassAvailabilityBuilder)
}

struct RenderPassAvailabilityBuilder {
    let renderSurfaceMode: ViewMode

    var labelsEnabled: Bool = false
    var pinsEnabled: Bool = false
    var debugOverlayEnabled: Bool = false
    /// Unlike the content-driven flags above, the starfield is on by default and
    /// is turned off by settings, so it starts enabled instead of accumulating.
    var starfieldEnabled: Bool = true
    /// Content-driven: on once a frame has scene models to draw.
    var sceneModelsEnabled: Bool = false
    /// Content-driven: on once a frame has layers of the app's data to draw.
    var appLayersEnabled: Bool = false

    func build() -> RenderPassAvailability {
        RenderPassAvailability(renderSurfaceMode: renderSurfaceMode,
                               labelsEnabled: labelsEnabled,
                               pinsEnabled: pinsEnabled,
                               debugOverlayEnabled: debugOverlayEnabled,
                               starfieldEnabled: starfieldEnabled,
                               sceneModelsEnabled: sceneModelsEnabled,
                               appLayersEnabled: appLayersEnabled)
    }
}
