// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap

@main
struct ImmersiveMapBuildingsMacApp: App {
    var body: some Scene {
        WindowGroup("ImmersiveMap Buildings and Shadows") {
            BuildingsScreen()
        }
        .defaultSize(width: 1100, height: 800)
    }
}

/// Extruded buildings and the directional shadows they cast. Both are flat
/// presentation only, so the app opens at street level where the map is already
/// a plane.
///
/// `buildingExtrusionMode` decides how buildings are composited over the map.
/// The default `.translucent` renders them into an offscreen image and blends
/// it, which is why translucent buildings carry no depth and never occlude
/// scene models; `.solid` is depth-correct and `.solidAtHighZoom` interpolates
/// between the two as the camera comes down.
private struct BuildingsScreen: View {
    @State private var camera = ImmersiveMapCameraController()
    @State private var extrusionMode: ExtrusionChoice = .solidAtHighZoom
    @State private var shadowsEnabled = true
    @State private var shadowStrength: Double = 0.5
    @State private var shadowResolution: Double = 2048
    @State private var coverageCameraDistances: Double = 16
    @State private var sunAzimuth: Double = 235
    @State private var sunElevation: Double = 40

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
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ImmersiveMapView()
                .camera(camera, position: Self.tokyoStreet)
                .buildingExtrusionMode(extrusionMode.mode)
                .sceneSettings(sceneSettings)
                .enableCameraUIControls()
                .ignoresSafeArea()

            controls
                .padding(20)
        }
    }

    private var sceneSettings: ImmersiveMapSettings.SceneSettings {
        var scene = ImmersiveMapSettings.default.scene
        scene.shadows.isEnabled = shadowsEnabled
        scene.shadows.strength = Float(shadowStrength)
        scene.shadows.mapResolution = Int(shadowResolution)
        scene.shadows.coverageCameraDistances = Float(coverageCameraDistances)
        scene.light.direction = sunDirection
        return scene
    }

    /// The light direction points **towards** the sun in the flat basis
    /// (+X east, +Y north, +Z up), so azimuth and elevation map onto it
    /// directly. A low elevation throws long shadows.
    private var sunDirection: SIMD3<Float> {
        let azimuth = sunAzimuth * .pi / 180
        let elevation = sunElevation * .pi / 180
        return SIMD3<Float>(Float(cos(elevation) * sin(azimuth)),
                            Float(cos(elevation) * cos(azimuth)),
                            Float(sin(elevation)))
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Picker("Extrusion", selection: $extrusionMode) {
                    ForEach(ExtrusionChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 340)

                Toggle("Shadows", isOn: $shadowsEnabled)
                    .toggleStyle(.switch)

                Divider().frame(height: 20)

                Button("Tokyo") {
                    camera.fly(to: Self.tokyoStreet, options: CameraFlightOptions(duration: 2.0))
                }
                Button("Dubai") {
                    camera.fly(to: Self.dubaiStreet,
                               options: CameraFlightOptions(duration: 3.0,
                                                            routeStyle: .greatCircle,
                                                            altitudeStyle: .overviewFirst))
                }
            }

            HStack(spacing: 18) {
                slider("Sun azimuth", value: $sunAzimuth, range: 0...360, format: "%.0f")
                slider("Sun elevation", value: $sunElevation, range: 5...85, format: "%.0f")
                slider("Strength", value: $shadowStrength, range: 0...1)
                slider("Map px", value: $shadowResolution, range: 256...4096, format: "%.0f")
                slider("Coverage", value: $coverageCameraDistances, range: 2...48, format: "%.0f")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func slider(_ title: String,
                        value: Binding<Double>,
                        range: ClosedRange<Double>,
                        format: String = "%.2f") -> some View {
        VStack(spacing: 2) {
            Text("\(title): \(value.wrappedValue, specifier: format)")
                .font(.system(size: 11, design: .monospaced))
            Slider(value: value, in: range)
                .frame(width: 140)
        }
    }

    private static let tokyoStreet = ImmersiveMapCameraPosition(
        latitudeDegrees: 35.6595,
        longitudeDegrees: 139.7005,
        zoom: 16.8,
        bearing: 0.55,
        pitch: 1.02
    )

    private static let dubaiStreet = ImmersiveMapCameraPosition(
        latitudeDegrees: 25.1972,
        longitudeDegrees: 55.2744,
        zoom: 16.4,
        bearing: -0.35,
        pitch: 1.0
    )
}
