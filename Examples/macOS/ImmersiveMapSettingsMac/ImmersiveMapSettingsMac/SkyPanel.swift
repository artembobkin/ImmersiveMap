// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap

/// The sky of the globe presentation: the space background, the starfield
/// behind the planet, and the atmosphere around its limb. All live on
/// `settings.scene`; transparent space leaves everything outside the globe
/// unpainted, so what the app draws behind the map continues around the
/// planet. The flat map's fog band has no switch: it is always on and takes
/// the map's clear colour.
struct SkyPanel: View {
    @Binding var settings: ImmersiveMapSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelRow {
                Toggle("Transparent space", isOn: $settings.scene.space.isTransparent)
                    .toggleStyle(.switch)
                // The starfield is a GPU buffer built once at startup, not a
                // uniform: a new count means new geometry and a new renderer.
                DeferredValueSlider("Stars",
                                    value: Double(settings.scene.starfield.starCount),
                                    range: 0...8000,
                                    step: 100,
                                    format: "%.0f") { newValue in
                    settings.scene.starfield.starCount = Int(newValue)
                }
            }
            PanelRow {
                // The atmosphere is a per-frame uniform: every field applies
                // live. Off keeps the thin limb glow that hides the mesh edge.
                Toggle("Atmosphere", isOn: $settings.scene.atmosphere.isEnabled)
                    .toggleStyle(.switch)
                ColorPicker("Colour", selection: atmosphereColor, supportsOpacity: false)
                    .disabled(settings.scene.atmosphere.isEnabled == false)
                ValueSlider("Intensity",
                            value: $settings.scene.atmosphere.intensity.asDouble,
                            range: 0...2,
                            format: "%.2f")
                    .disabled(settings.scene.atmosphere.isEnabled == false)
                ValueSlider("Thickness",
                            value: $settings.scene.atmosphere.thickness.asDouble,
                            range: 0.25...3,
                            format: "%.2f")
                    .disabled(settings.scene.atmosphere.isEnabled == false)
                ValueSlider("Sun influence",
                            value: $settings.scene.atmosphere.sunInfluence.asDouble,
                            range: 0...1,
                            format: "%.2f")
                    .disabled(settings.scene.atmosphere.isEnabled == false)
            }
        }
    }

    /// The halo colour as a SwiftUI color and back, in the sRGB space the
    /// engine reads it in.
    private var atmosphereColor: Binding<Color> {
        Binding {
            let color = settings.scene.atmosphere.color
            return Color(.sRGB, red: Double(color.x), green: Double(color.y), blue: Double(color.z))
        } set: { newValue in
            guard let components = NSColor(newValue).usingColorSpace(.sRGB) else { return }
            settings.scene.atmosphere.color = SIMD3<Float>(Float(components.redComponent),
                                                           Float(components.greenComponent),
                                                           Float(components.blueComponent))
        }
    }
}
