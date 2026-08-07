// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMap

/// One branch of `ImmersiveMapSettings` per sidebar entry, with the camera
/// position where that branch is actually visible: shadows need street level,
/// the terminator needs the globe, the globe-to-flat morph needs the zoom band
/// where it happens.
enum PlaygroundSection: String, CaseIterable, Identifiable, Hashable {
    case labels
    case buildings
    case earthScene
    case style
    case presentation
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .labels: "Labels"
        case .buildings: "Buildings and shadows"
        case .earthScene: "Earth scene"
        case .style: "Style"
        case .presentation: "Presentation"
        case .diagnostics: "Diagnostics"
        }
    }

    var symbolName: String {
        switch self {
        case .labels: "textformat"
        case .buildings: "building.2"
        case .earthScene: "sun.max"
        case .style: "paintpalette"
        case .presentation: "globe"
        case .diagnostics: "speedometer"
        }
    }

    var summary: String {
        switch self {
        case .labels:
            """
            `settings.labels`: which name field the tiles are read for, and which \
            labels reach the screen at which zoom. Every field here is baked into \
            prepared tiles, so a change re-prepares them.
            """
        case .buildings:
            """
            `settings.style.buildingExtrusionMode` and `settings.scene` \
            (light, shadows). Flat presentation only, and all of it is per-frame \
            uniforms, so it applies without touching a single tile.
            """
        case .earthScene:
            """
            `settings.scene.earth`, `.starfield` and `.space`: the visible Sun, \
            the day/night terminator and what is drawn outside the globe.
            """
        case .style:
            """
            The palette is the map style, not a settings field: build an \
            `ImmersiveMapTilesMapStyle` from a configuration and hand it over. \
            Colors are baked into prepared tiles, the extrusion alpha is not.
            """
        case .presentation:
            """
            `settings.presentation` decides where the globe unfurls into a plane \
            and how large the globe is; `settings.camera` decides how far the \
            camera may go. Zoom across the window and watch the readout.
            """
        case .diagnostics:
            """
            The debug panel, FXAA, how hard the frame loop runs and how much the \
            tile caches keep. The cheap frame-level switches and the expensive \
            cache ones sit side by side on purpose.
            """
        }
    }

    var cameraPosition: ImmersiveMapCameraPosition {
        switch self {
        case .labels:
            ImmersiveMapCameraPosition(latitudeDegrees: 48.8566,
                                       longitudeDegrees: 2.3522,
                                       zoom: 13.5,
                                       bearing: 0,
                                       pitch: 0.2)
        case .buildings:
            ImmersiveMapCameraPosition(latitudeDegrees: 35.6595,
                                       longitudeDegrees: 139.7005,
                                       zoom: 16.8,
                                       bearing: 0.55,
                                       pitch: 1.02)
        case .earthScene:
            ImmersiveMapCameraPosition(latitudeDegrees: 20,
                                       longitudeDegrees: 10,
                                       zoom: 1.5,
                                       bearing: 0,
                                       pitch: 0.08)
        case .style:
            ImmersiveMapCameraPosition(latitudeDegrees: 45.4408,
                                       longitudeDegrees: 12.3155,
                                       zoom: 12.4,
                                       bearing: 0,
                                       pitch: 0.35)
        case .presentation:
            // Mid-window at this latitude: the sphere is already unfurling but
            // has not finished, which is the only place the morph is visible.
            ImmersiveMapCameraPosition(latitudeDegrees: 41.9,
                                       longitudeDegrees: 12.5,
                                       zoom: 6.4,
                                       bearing: 0,
                                       pitch: 0.3)
        case .diagnostics:
            ImmersiveMapCameraPosition(latitudeDegrees: 51.5072,
                                       longitudeDegrees: -0.1276,
                                       zoom: 14.2,
                                       bearing: 0,
                                       pitch: 0.6)
        }
    }
}
