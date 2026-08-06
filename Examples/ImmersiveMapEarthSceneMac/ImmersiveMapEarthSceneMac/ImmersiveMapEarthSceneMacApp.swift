// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap

@main
struct ImmersiveMapEarthSceneMacApp: App {
    var body: some Scene {
        WindowGroup("ImmersiveMap Earth Scene") {
            EarthSceneScreen()
        }
        .defaultSize(width: 1100, height: 800)
    }
}

/// The Earth scene: a visible sun, the day/night terminator across the globe,
/// and the starfield behind it. All of it lives on
/// `ImmersiveMapSettings.SceneSettings` and is attached with
/// `.sceneSettings(...)`; `.earthScene(isEnabled:)` is the one-line shorthand
/// for turning the whole package on and off.
///
/// The sun position follows a wall date. `EarthSceneTimeMode.realtime` tracks
/// the clock; `.fixed(Date)` pins it, which is what the hour slider does, so
/// the terminator sweeps the planet as you drag.
private struct EarthSceneScreen: View {
    @State private var camera = ImmersiveMapCameraController()
    @State private var isEarthSceneEnabled = true
    @State private var followsRealtime = true
    @State private var hourOfDay: Double = 12
    @State private var nightBrightness: Double = 0.18
    @State private var terminatorFadeWidth: Double = 0.12
    @State private var sunGlow: Double = 0.75
    @State private var limbHalo: Double = 0.35
    @State private var starCount: Double = 2000

    var body: some View {
        ZStack(alignment: .bottom) {
            ImmersiveMapView()
                .camera(camera, position: Self.overview)
                .sceneSettings(sceneSettings)
                .enableCameraUIControls()
                .ignoresSafeArea()

            controls
                .padding(20)
        }
    }

    private var sceneSettings: ImmersiveMapSettings.SceneSettings {
        var scene = ImmersiveMapSettings.default.scene

        scene.earth.isEnabled = isEarthSceneEnabled
        scene.earth.timeMode = followsRealtime ? .realtime : .fixed(fixedDate)
        scene.earth.nightSideBrightness = Float(nightBrightness)
        scene.earth.terminatorFadeWidth = Float(terminatorFadeWidth)
        scene.earth.sun.glowIntensity = Float(sunGlow)
        scene.earth.sun.limbHaloIntensity = Float(limbHalo)

        scene.starfield.starCount = Int(starCount)

        return scene
    }

    /// Today at the chosen UTC hour. The sun direction is derived from this
    /// date, so a fixed date makes the whole scene deterministic.
    private var fixedDate: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let startOfDay = calendar.startOfDay(for: Date())
        return startOfDay.addingTimeInterval(hourOfDay * 3600)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Toggle("Earth scene", isOn: $isEarthSceneEnabled)
                    .toggleStyle(.switch)
                Toggle("Follow the clock", isOn: $followsRealtime)
                    .toggleStyle(.switch)
                    .disabled(isEarthSceneEnabled == false)

                slider("Hour, UTC", value: $hourOfDay, range: 0...24, format: "%.1f")
                    .disabled(followsRealtime || isEarthSceneEnabled == false)

                Divider().frame(height: 20)

                Button("Globe") {
                    camera.fly(to: Self.overview,
                               options: CameraFlightOptions(duration: 2.4,
                                                            routeStyle: .greatCircle,
                                                            altitudeStyle: .overviewFirst))
                }
                Button("Terminator") {
                    // A low, tilted globe view looking along the terminator is
                    // where the day/night fade reads best.
                    camera.fly(to: Self.terminatorView,
                               options: CameraFlightOptions(duration: 2.4,
                                                            routeStyle: .greatCircle,
                                                            altitudeStyle: .direct))
                }
            }

            HStack(spacing: 18) {
                slider("Night brightness", value: $nightBrightness, range: 0...1)
                slider("Terminator fade", value: $terminatorFadeWidth, range: 0.01...0.5)
                slider("Sun glow", value: $sunGlow, range: 0...1)
                slider("Limb halo", value: $limbHalo, range: 0...1)
                slider("Stars", value: $starCount, range: 0...8000, format: "%.0f")
            }
            .disabled(isEarthSceneEnabled == false)
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

    private static let overview = ImmersiveMapCameraPosition(
        latitudeDegrees: 20,
        longitudeDegrees: 10,
        zoom: 1.5,
        bearing: 0,
        pitch: 0.08
    )

    private static let terminatorView = ImmersiveMapCameraPosition(
        latitudeDegrees: 5,
        longitudeDegrees: 75,
        zoom: 2.4,
        bearing: 0,
        pitch: 0.5
    )
}
