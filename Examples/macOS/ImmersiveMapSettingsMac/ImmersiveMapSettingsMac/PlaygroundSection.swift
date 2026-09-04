// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMap

/// One branch of `ImmersiveMapSettings` per sidebar entry, with the camera
/// position where that branch is actually visible: shadows need street level,
/// the terminator needs the globe, the globe-to-flat morph needs the zoom band
/// where it happens.
enum PlaygroundSection: String, CaseIterable, Identifiable, Hashable {
    case labels
    case streetscape
    case buildings
    case sky
    case style
    case presentation
    case camera
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .labels: "Labels"
        case .streetscape: "Streetscape"
        case .buildings: "Buildings and shadows"
        case .sky: "Sky"
        case .style: "Style"
        case .presentation: "Presentation"
        case .camera: "Camera"
        case .diagnostics: "Diagnostics"
        }
    }

    var symbolName: String {
        switch self {
        case .labels: "textformat"
        case .streetscape: "road.lanes"
        case .buildings: "building.2"
        case .sky: "sparkles"
        case .style: "paintpalette"
        case .presentation: "globe"
        case .camera: "camera.aperture"
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
        case .streetscape:
            """
            `settings.tiles.streetscape`: the measured carriageway surfaces and \
            the paint on them, a second tile archive the service serves next to \
            the map tiles at street zoom. Off, roads are casing and fill with \
            bare asphalt; on, every street-zoom tile is two requests, and the \
            prepared tiles are re-baked either way.
            """
        case .buildings:
            """
            `settings.style.buildingExtrusionMode` and `settings.scene` \
            (light, shadows). Flat presentation only, and all of it is per-frame \
            uniforms, so it applies without touching a single tile.
            """
        case .sky:
            """
            `settings.scene.starfield` and `.space`: the stars behind the \
            planet and whether anything outside the globe is painted at all.
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
            and how large the globe is. Zoom across the window and watch the \
            readout; the zoom limits that can pin either surface live in the \
            Camera section.
            """
        case .camera:
            """
            `settings.camera` is every limit on where the camera may go: the \
            zoom range, the tilt floor and ceiling, and how far it may rotate \
            away from north. Commands are clamped, not refused, and the globe \
            still eases tilt and rotation in with zoom on top of these limits.
            """
        case .diagnostics:
            """
            The debug panel, FXAA, how hard the frame loop runs and how large \
            the disk tile caches may grow. The cheap frame-level switches and \
            the expensive cache ones sit side by side on purpose.
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
        case .streetscape:
            // The Tverskaya junction in central Moscow, where the archive has
            // every figure: surfaces, separators, a bus lane, parking bays.
            ImmersiveMapCameraPosition(latitudeDegrees: 55.7570,
                                       longitudeDegrees: 37.6110,
                                       zoom: 16.6,
                                       bearing: 0,
                                       pitch: 0.3)
        case .buildings:
            ImmersiveMapCameraPosition(latitudeDegrees: 35.6595,
                                       longitudeDegrees: 139.7005,
                                       zoom: 16.8,
                                       bearing: 0.55,
                                       pitch: 1.02)
        case .sky:
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
        case .camera:
            // Midtown Manhattan with tilt and rotation already applied, so the
            // floor, ceiling and bearing cap all have something visible to bite.
            ImmersiveMapCameraPosition(latitudeDegrees: 40.7527,
                                       longitudeDegrees: -73.9772,
                                       zoom: 15.6,
                                       bearing: 0.6,
                                       pitch: 0.95)
        case .diagnostics:
            ImmersiveMapCameraPosition(latitudeDegrees: 51.5072,
                                       longitudeDegrees: -0.1276,
                                       zoom: 14.2,
                                       bearing: 0,
                                       pitch: 0.6)
        }
    }
}
