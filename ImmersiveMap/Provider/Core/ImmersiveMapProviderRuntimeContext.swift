// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// Everything the runtime derives from the configured map style: the live
/// style object, the label profile that says which MVT properties carry label
/// text, and the base colors. The tile source contributes nothing here; it is
/// only a URL the loader fetches bytes from.
struct ImmersiveMapProviderRuntimeContext {
    let mapStyle: any ImmersiveMapStyle
    let labelProviderProfile: any VectorTileLabelProviderProfile
    let mapBaseColors: ImmersiveMapBaseColors

    init(settings: ImmersiveMapSettings) {
        self.init(mapStyle: settings.mapStyle, settings: settings)
    }

    init(mapStyle: AnyImmersiveMapMapStyle, settings: ImmersiveMapSettings) {
        let runtimeMapStyle = mapStyle.makeRuntimeMapStyle(settings: settings.style)
        self.mapStyle = runtimeMapStyle
        self.labelProviderProfile = mapStyle.makeLabelProviderProfile(settings: settings)
        self.mapBaseColors = runtimeMapStyle.getMapBaseColors()
    }
}
