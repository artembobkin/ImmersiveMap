// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap

/// The sky of both presentations: the space background, the starfield
/// behind the planet and the atmosphere around its limb on the globe, the
/// sky gradient and the ground fog of the flat map. All live on
/// `settings.scene`. Transparent space leaves everything outside the globe
/// unpainted, so what the app draws behind the map continues around the
/// planet. The ground fog's lengths are in camera distances, so the same
/// fraction of the visible ground is fogged at every zoom. Tilt the camera
/// to the horizon to see it.
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
            PanelRow {
                // The fog is a per-frame uniform too. Off leaves the sky the
                // clear colour and a thin seam-hiding band at the line.
                Toggle("Fog", isOn: $settings.scene.fog.isEnabled)
                    .toggleStyle(.switch)
                ColorPicker("Sky", selection: fogColor(\.skyColor), supportsOpacity: false)
                    .disabled(settings.scene.fog.isEnabled == false)
                ColorPicker("Horizon", selection: fogColor(\.horizonColor), supportsOpacity: false)
                    .disabled(settings.scene.fog.isEnabled == false)
            }
            PanelRow {
                // The ground fog veils the far ground. Its values follow the
                // zoom by default. A slider here sets one value at every zoom.
                Toggle("Ground fog", isOn: $settings.scene.groundFog.isEnabled)
                    .toggleStyle(.switch)
                ValueSlider("Density /km",
                            value: groundFogValue(\.densityPerKilometer),
                            range: 0...30,
                            format: "%.1f")
                    .disabled(settings.scene.groundFog.isEnabled == false)
                ValueSlider("Fog from, m",
                            value: groundFogValue(\.startDistanceMeters),
                            range: 0...5000,
                            format: "%.0f")
                    .disabled(settings.scene.groundFog.isEnabled == false)
            }
        }
    }

    /// One of the ground fog's zoom curves as one slider value: its value, or
    /// its last stop's for a curve. Setting it makes it the same at every
    /// zoom.
    private func groundFogValue(
        _ keyPath: WritableKeyPath<ImmersiveMapSettings.GroundFogSettings, ImmersiveMapZoomCurve>
    ) -> Binding<Double> {
        Binding {
            Double(settings.scene.groundFog[keyPath: keyPath].stops.last?.value ?? 0)
        } set: { newValue in
            settings.scene.groundFog[keyPath: keyPath] = ImmersiveMapZoomCurve(Float(newValue))
        }
    }

    /// One of the fog's colours as a SwiftUI color and back, in the sRGB
    /// space the engine reads it in.
    private func fogColor(_ keyPath: WritableKeyPath<ImmersiveMapSettings.FogSettings, SIMD3<Float>>) -> Binding<Color> {
        Binding {
            let color = settings.scene.fog[keyPath: keyPath]
            return Color(.sRGB, red: Double(color.x), green: Double(color.y), blue: Double(color.z))
        } set: { newValue in
            guard let components = NSColor(newValue).usingColorSpace(.sRGB) else { return }
            settings.scene.fog[keyPath: keyPath] = SIMD3<Float>(Float(components.redComponent),
                                                                Float(components.greenComponent),
                                                                Float(components.blueComponent))
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
