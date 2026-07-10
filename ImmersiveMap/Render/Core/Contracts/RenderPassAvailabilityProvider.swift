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

    func build() -> RenderPassAvailability {
        RenderPassAvailability(renderSurfaceMode: renderSurfaceMode,
                               labelsEnabled: labelsEnabled,
                               avatarsEnabled: avatarsEnabled,
                               debugOverlayEnabled: debugOverlayEnabled)
    }
}
