// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

protocol RenderPassAvailabilityProvider: AnyObject {
    func contributePassAvailability(settings: ImmersiveMapSettings,
                                    builder: inout RenderPassAvailabilityBuilder)
}

struct RenderPassAvailabilityBuilder {
    let renderSurfaceMode: ViewMode

    var terrainEnabled: Bool = false
    var labelsEnabled: Bool = false
    var avatarsEnabled: Bool = false
    var debugOverlayEnabled: Bool = false

    func build() -> RenderPassAvailability {
        RenderPassAvailability(renderSurfaceMode: renderSurfaceMode,
                               terrainEnabled: terrainEnabled,
                               labelsEnabled: labelsEnabled,
                               avatarsEnabled: avatarsEnabled,
                               debugOverlayEnabled: debugOverlayEnabled)
    }
}
