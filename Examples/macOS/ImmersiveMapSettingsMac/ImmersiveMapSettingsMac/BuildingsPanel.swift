// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import simd
import ImmersiveMap

/// Extruded buildings and the directional shadows they cast. Both are flat
/// presentation only, which is why this section opens at street level where the
/// map is already a plane.
///
/// `buildingExtrusionMode` decides how buildings are composited over the map.
/// The default `.translucent` renders them into an offscreen image and blends
/// it, which is why translucent buildings carry no depth and never occlude
/// scene models; `.solid` is depth-correct and `.solidAtHighZoom` interpolates
/// between the two as the camera comes down.
struct BuildingsPanel: View {
    @Binding var settings: ImmersiveMapSettings

    private enum ExtrusionChoice: String, CaseIterable, Identifiable {
        case translucent
        case solid
        case solidAtHighZoom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .translucent: "Translucent"
            case .solid: "Solid"
            case .solidAtHighZoom: "Solid at high zoom"
            }
        }

        var mode: ImmersiveMapSettings.StyleSettings.BuildingExtrusionMode {
            switch self {
            case .translucent: .translucent
            case .solid: .solid
            case .solidAtHighZoom: .solidAtHighZoom(startZoom: 16.5, endZoom: 17)
            }
        }

        init(mode: ImmersiveMapSettings.StyleSettings.BuildingExtrusionMode) {
            switch mode {
            case .translucent: self = .translucent
            case .solid: self = .solid
            case .solidAtHighZoom: self = .solidAtHighZoom
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelRow {
                Picker("Extrusion", selection: extrusionChoice) {
                    ForEach(ExtrusionChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 340)

                Toggle("Shadows", isOn: $settings.scene.shadows.isEnabled)
                    .toggleStyle(.switch)

                ValueSlider("Blend alpha",
                            value: $settings.style.buildingExtrusionAlpha.asDouble,
                            range: 0...1,
                            width: 120)
                    .disabled(ExtrusionChoice(mode: settings.style.buildingExtrusionMode) == .solid)
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
            }
            .disabled(settings.scene.shadows.isEnabled == false)
        }
    }

    private var extrusionChoice: Binding<ExtrusionChoice> {
        Binding(get: { ExtrusionChoice(mode: settings.style.buildingExtrusionMode) },
                set: { settings.style.buildingExtrusionMode = $0.mode })
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
