// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap

/// Globe and plane are not two modes with a switch between them. The engine
/// resolves a continuous transition in `0...1` from the camera zoom and morphs
/// the geometry across it, and `settings.presentation` is where that window
/// lives: it opens at `automaticTransitionStartZoom` and is
/// `automaticTransitionSpan` zoom levels wide.
///
/// The window is also stretched by latitude, because a Mercator plane inflates
/// away from the equator and the unfurl would otherwise run at different speeds
/// in Rome and in Reykjavik. The readout below recomputes the same value the
/// renderer uses, so dragging the sliders moves the numbers with the map.
struct PresentationPanel: View {
    @Binding var settings: ImmersiveMapSettings
    let camera: ImmersiveMapCameraController

    @State private var position: ImmersiveMapCameraPosition?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelRow {
                ValueSlider("Morph starts at z",
                            value: $settings.presentation.automaticTransitionStartZoom,
                            range: 2...12,
                            step: 0.1,
                            format: "%.1f")
                ValueSlider("Window, levels",
                            value: $settings.presentation.automaticTransitionSpan,
                            range: 0.2...6,
                            step: 0.1,
                            format: "%.1f")
                ValueSlider("Globe radius",
                            value: $settings.presentation.globeRadiusScale,
                            range: 0.05...0.4)
            }

            readout
        }
        .onAppear {
            position = camera.currentCameraPosition()
            camera.onCameraPositionChanged = { newPosition in
                // The engine notifies synchronously from its settings-apply
                // path, which runs inside SwiftUI's update pass: a slider here
                // writes `settings`, the map view re-renders, the settings are
                // applied, the camera re-clamps and notifies. Writing @State
                // there is the "modifying state during view update" case, so
                // the readout is updated on the next runloop turn instead.
                DispatchQueue.main.async {
                    position = newPosition
                }
            }
        }
        .onDisappear {
            camera.onCameraPositionChanged = nil
        }
    }

    private var readout: some View {
        HStack(spacing: 14) {
            Text(String(format: "zoom %.2f", position?.zoom ?? 0))
            Text(String(format: "latitude %.1f°", position?.latitudeDegrees ?? 0))
            Text(String(format: "transition %.2f", transition))
            Text(surfaceDescription)
                .foregroundStyle(.tint)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
    }

    /// The same clamp `PresentationStateResolver` applies, latitude extension
    /// included.
    private var transition: Double {
        guard let position else {
            return 0
        }
        let latitude = position.latitudeDegrees * .pi / 180
        let latitudeSpanExtension = log2(1.0 / max(cos(latitude), 0.01))
        let span = max(.leastNonzeroMagnitude,
                       settings.presentation.automaticTransitionSpan + latitudeSpanExtension)
        let raw = (position.zoom - settings.presentation.automaticTransitionStartZoom) / span
        return min(max(raw, 0), 1)
    }

    /// The morph phase and the surface the engine picks from it are not the
    /// same thing: the flat surface is selected at a fully completed
    /// transition only, so everything below 1 still renders as a sphere being
    /// unfurled.
    private var surfaceDescription: String {
        switch transition {
        case 0: "globe"
        case 1: "flat"
        default: "morphing, still a sphere"
        }
    }
}
