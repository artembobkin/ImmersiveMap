// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

/// Everything the runtime derives from the configured map style: the live
/// style object, the label profile that says which MVT properties carry label
/// text, and the base colors. The tile source contributes nothing here; it is
/// only a URL the loader fetches bytes from.
///
/// The `Style` folder: the public style API (`ImmersiveMapMapStyle`,
/// `ImmersiveMapVectorTileStyle`, the building and road readings), the
/// resolved style the parser reads (`FeatureStyle` and the internal
/// `ImmersiveMapStyle` protocol), the bridge between the two
/// (`GenericVectorTileStyle`), the label profiles in `Labels/`, and the
/// built-in style in `Default/`. Everything about interpreting a tile's
/// bytes lives here; nothing about fetching them does. No Metal, no
/// parsing, no networking.
struct MapStyleRuntime {
    let mapStyle: any ImmersiveMapStyle
    let labelProfile: any LabelStyleProfile
    let mapBaseColors: ImmersiveMapBaseColors

    init(settings: ImmersiveMapSettings) {
        self.init(mapStyle: settings.mapStyle, settings: settings)
    }

    init(mapStyle: AnyImmersiveMapMapStyle, settings: ImmersiveMapSettings) {
        let runtimeMapStyle = mapStyle.makeRuntimeMapStyle(settings: settings.style)
        self.mapStyle = runtimeMapStyle
        self.labelProfile = mapStyle.makeLabelProfile(settings: settings)
        self.mapBaseColors = runtimeMapStyle.getMapBaseColors()
    }
}
