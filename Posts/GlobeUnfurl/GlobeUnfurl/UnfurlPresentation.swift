// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMap

/// The settings that decide where the sphere becomes a plane, tuned so the
/// change is the subject of the shot rather than a detail of it.
///
/// The engine does not switch between two modes. `PresentationStateResolver`
/// turns the camera's zoom into a transition in 0...1, both the globe and the
/// flat state are produced every frame, and the vertex shader morphs the
/// geometry between them. There is no frame where the map is swapped, which is
/// exactly what this demo has to show: at the default span the whole change
/// happens inside a single zoom level and reads as a cut if the camera is
/// moving at any speed.
enum UnfurlPresentation {
    /// The morph runs from zoom 5 to zoom 7.5 instead of the default 6 to 7.
    /// Two and a half zoom levels is slow enough that the sheet can be watched
    /// unrolling, and it puts the halfway point at 6.25, which is where the
    /// storyboard stops to hold the half-unrolled state.
    static let midpointZoom = 6.25

    static var settings: ImmersiveMapSettings.PresentationSettings {
        var presentation = ImmersiveMapSettings.default.presentation
        presentation.automaticTransitionStartZoom = 5.0
        presentation.automaticTransitionSpan = 2.5
        return presentation
    }

    /// The globe is normally free to rotate under the camera below the bearing
    /// unlock zoom, and the pitch is clamped towards zero as the camera pulls
    /// away. Both limits are lifted here: the storyboard holds one bearing and
    /// one pitch across the whole range so the only thing that changes on
    /// screen is the shape of the world.
    static var camera: ImmersiveMapSettings.CameraSettings {
        var camera = ImmersiveMapSettings.default.camera
        camera.globeBearingUnlockZoom = 0
        camera.globePitchUnlockZoom = 0
        return camera
    }
}
