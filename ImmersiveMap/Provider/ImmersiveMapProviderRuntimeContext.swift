// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

struct ImmersiveMapProviderRuntimeContext {
    let mapStyle: any ImmersiveMapStyle
    let labelProviderProfile: any VectorTileLabelProviderProfile
    let mapBaseColors: ImmersiveMapBaseColors

    init(settings: ImmersiveMapSettings) {
        self.init(tileProvider: settings.tileProvider,
                  mapStyle: settings.mapStyle,
                  settings: settings)
    }

    init(tileProvider: AnyImmersiveMapTileProvider,
         mapStyle: AnyImmersiveMapMapStyle,
         settings: ImmersiveMapSettings) {
        let runtimeMapStyle = mapStyle.makeRuntimeMapStyle(providerID: tileProvider.id,
                                                           settings: settings.style)
        self.mapStyle = runtimeMapStyle
        self.labelProviderProfile = tileProvider.makeLabelProviderProfile(settings: settings)
        self.mapBaseColors = runtimeMapStyle.getMapBaseColors()
    }
}
