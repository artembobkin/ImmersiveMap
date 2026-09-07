// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import simd
import ImmersiveMap

/// Extruded buildings and the directional shadows they cast. Both are flat
/// presentation only, which is why this section opens at street level where the
/// map is already a plane.
///
/// `buildingExtrusionEnabled` is the master switch: off, no building rises
/// and every footprint stays a flat fill, which is what the globe shows too.
/// It is baked into the prepared tiles, so the toggle re-parses them.
///
/// Buildings always draw solid and depth-correct; the translucent
/// compositing path was removed.
///
/// Shadows have a strength and a tint: the tint is the cast of the light a
/// shadowed surface still gets (the sky), applied on top of the strength, and
/// every receiver takes it, so one picker recolors the shadows on the ground,
/// the buildings and the models alike.
struct BuildingsPanel: View {
    @Binding var settings: ImmersiveMapSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelRow {
                // Extrusions are baked into the prepared tiles, so this
                // toggle re-parses them (a moment of loading is expected).
                Toggle("3D buildings", isOn: $settings.style.buildingExtrusionEnabled)
                    .toggleStyle(.switch)

                Toggle("Shadows", isOn: $settings.scene.shadows.isEnabled)
                    .toggleStyle(.switch)

                // Shaped roofs are baked into the prepared tiles, so this
                // toggle re-parses them (a moment of loading is expected).
                Toggle("Roof shapes", isOn: $settings.style.buildingRoofShapesEnabled)
                    .toggleStyle(.switch)
            }

            PanelRow {
                ValueSlider("Sun azimuth", value: sunAzimuth, range: 0...360, format: "%.0f")
                ValueSlider("Sun elevation", value: sunElevation, range: 5...85, format: "%.0f")
                ValueSlider("Strength",
                            value: $settings.scene.shadows.strength.asDouble,
                            range: 0...1)
                ValueSlider("Map px",
                            value: $settings.scene.shadows.mapResolution.asDouble,
                            range: 256...4096,
                            format: "%.0f")
                ValueSlider("Coverage",
                            value: $settings.scene.shadows.coverageCameraDistances.asDouble,
                            range: 2...48,
                            format: "%.0f")
                ValueSlider("Caster height",
                            value: $settings.scene.shadows.maxCasterHeightMeters.asDouble,
                            range: 10...500,
                            format: "%.0f")
                ValueSlider("Normal offset",
                            value: $settings.scene.shadows.normalOffsetTexels.asDouble,
                            range: 0...8,
                            format: "%.1f")
                ValueSlider("Softness",
                            value: $settings.scene.shadows.softness.asDouble,
                            range: 1...2.5,
                            format: "%.2f")
                ColorPicker("Tint", selection: shadowTint, supportsOpacity: false)
                    .frame(width: 100)
            }
            .disabled(settings.scene.shadows.isEnabled == false)
        }
    }

    /// The shadow tint as a SwiftUI color and back, in the sRGB space the
    /// setting is stated in.
    private var shadowTint: Binding<Color> {
        Binding(get: {
            let tint = settings.scene.shadows.tint
            return Color(.sRGB, red: Double(tint.x), green: Double(tint.y), blue: Double(tint.z))
        }, set: { newColor in
            guard let components = NSColor(newColor).usingColorSpace(.sRGB) else {
                return
            }
            settings.scene.shadows.tint = SIMD3<Float>(Float(components.redComponent),
                                                       Float(components.greenComponent),
                                                       Float(components.blueComponent))
        })
    }

    /// The light direction points **towards** the sun in the flat basis
    /// (+X east, +Y north, +Z up), so azimuth and elevation map onto it
    /// directly and can be read back out of it. A low elevation throws long
    /// shadows.
    private var sunAzimuth: Binding<Double> {
        Binding(get: { sunAngles.azimuth },
                set: { settings.scene.light.direction = sunDirection(azimuth: $0,
                                                                     elevation: sunAngles.elevation) })
    }

    private var sunElevation: Binding<Double> {
        Binding(get: { sunAngles.elevation },
                set: { settings.scene.light.direction = sunDirection(azimuth: sunAngles.azimuth,
                                                                     elevation: $0) })
    }

    private var sunAngles: (azimuth: Double, elevation: Double) {
        let direction = settings.scene.light.direction
        let length = max(Double(simd_length(direction)), .leastNormalMagnitude)
        let x = Double(direction.x) / length
        let y = Double(direction.y) / length
        let z = Double(direction.z) / length
        let azimuth = atan2(x, y) * 180 / .pi
        return (azimuth < 0 ? azimuth + 360 : azimuth, asin(z) * 180 / .pi)
    }

    private func sunDirection(azimuth: Double, elevation: Double) -> SIMD3<Float> {
        let azimuthRadians = azimuth * .pi / 180
        let elevationRadians = elevation * .pi / 180
        return SIMD3<Float>(Float(cos(elevationRadians) * sin(azimuthRadians)),
                            Float(cos(elevationRadians) * cos(azimuthRadians)),
                            Float(sin(elevationRadians)))
    }
}
