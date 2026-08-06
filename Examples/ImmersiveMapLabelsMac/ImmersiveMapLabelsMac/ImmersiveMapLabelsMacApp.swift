// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap

@main
struct ImmersiveMapLabelsMacApp: App {
    var body: some Scene {
        WindowGroup("ImmersiveMap Labels") {
            LabelsScreen()
        }
        .defaultSize(width: 1100, height: 800)
    }
}

/// Labels: MSDF text laid out and collided on the GPU, configured through
/// `.labelSettings(...)`. Everything here is a value on
/// `ImmersiveMapSettings.LabelSettings`, so the pattern is always the same:
/// take the current settings, change a field, hand them back to the view.
///
/// Language is the interesting one. It selects a different name field in the
/// vector tile, and it is part of the prepared-tile cache namespace
/// (`LabelLanguage.preparedTileCacheNamespaceKey`), so switching languages
/// re-prepares tiles rather than re-drawing the ones already in memory.
private struct LabelsScreen: View {
    @State private var camera = ImmersiveMapCameraController()
    @State private var language: ImmersiveMapSettings.LabelLanguage = .english
    @State private var fallbackPolicy: ImmersiveMapSettings.LabelFallbackPolicy = .international
    @State private var houseNumbersEnabled = true
    // Zoom thresholds are integers in LabelSettings, so the sliders step in
    // whole levels: a displayed 12.9 that quietly applies 12 is a worse demo
    // than a slider that only offers 12 and 13.
    @State private var settlementMaximumZoom = 12
    @State private var landmarkMinimumZoom = 15
    @State private var fadeSeconds: Double = 0.25

    var body: some View {
        ZStack(alignment: .bottom) {
            ImmersiveMapView()
                .camera(camera, position: Self.paris)
                .labelSettings(labelSettings)
                .enableCameraUIControls()
                .ignoresSafeArea()

            controls
                .padding(20)
        }
    }

    private var labelSettings: ImmersiveMapSettings.LabelSettings {
        var labels = ImmersiveMapSettings.default.labels
        labels.language = language
        labels.fallbackPolicy = fallbackPolicy
        labels.houseNumbers.enabled = houseNumbersEnabled
        // A settlement label is drawn up to its own maximum zoom and then gives
        // the screen to street and landmark labels.
        labels.settlementVisibility = ImmersiveMapSettings.LabelSettings.SettlementVisibilitySettings(
            capitalMaximumZoom: settlementMaximumZoom,
            cityMaximumZoom: settlementMaximumZoom,
            smallSettlementMaximumZoom: settlementMaximumZoom)
        labels.landmarks.minimumZoom = landmarkMinimumZoom
        labels.base.fadeInSeconds = fadeSeconds
        labels.base.fadeOutSeconds = fadeSeconds
        return labels
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Picker("Language", selection: $language) {
                    Text("English").tag(ImmersiveMapSettings.LabelLanguage.english)
                    Text("Русский").tag(ImmersiveMapSettings.LabelLanguage.russian)
                    Text("Français").tag(ImmersiveMapSettings.LabelLanguage.french)
                    Text("Deutsch").tag(ImmersiveMapSettings.LabelLanguage.german)
                    Text("Español").tag(ImmersiveMapSettings.LabelLanguage.spanish)
                    Text("Italiano").tag(ImmersiveMapSettings.LabelLanguage.italian)
                    Text("Português").tag(ImmersiveMapSettings.LabelLanguage.portuguese)
                    Text("Türkçe").tag(ImmersiveMapSettings.LabelLanguage.turkish)
                    // Any BCP-47-ish code works, the presets are a convenience.
                    Text("日本語 (ja)").tag(ImmersiveMapSettings.LabelLanguage("ja"))
                }
                .frame(width: 200)

                Picker("Fallback", selection: $fallbackPolicy) {
                    Text("International").tag(ImmersiveMapSettings.LabelFallbackPolicy.international)
                    Text("Local first").tag(ImmersiveMapSettings.LabelFallbackPolicy.localFirst)
                }
                .pickerStyle(.segmented)
                .frame(width: 240)

                Toggle("House numbers", isOn: $houseNumbersEnabled)
                    .toggleStyle(.switch)
            }

            HStack(spacing: 18) {
                zoomSlider("Settlements up to z", value: $settlementMaximumZoom, range: 4...18)
                zoomSlider("Landmarks from z", value: $landmarkMinimumZoom, range: 10...18)
                slider("Fade, s", value: $fadeSeconds, range: 0...1.5)

                Divider().frame(height: 20)

                Button("Paris") {
                    camera.fly(to: Self.paris, options: CameraFlightOptions(duration: 2.0))
                }
                Button("Tokyo") {
                    camera.fly(to: Self.tokyo,
                               options: CameraFlightOptions(duration: 3.0,
                                                            routeStyle: .greatCircle,
                                                            altitudeStyle: .overviewFirst))
                }
                Button("Globe") {
                    camera.fly(to: Self.overview,
                               options: CameraFlightOptions(duration: 2.6,
                                                            routeStyle: .greatCircle,
                                                            altitudeStyle: .overviewFirst))
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func slider(_ title: String,
                        value: Binding<Double>,
                        range: ClosedRange<Double>) -> some View {
        VStack(spacing: 2) {
            Text("\(title): \(value.wrappedValue, specifier: "%.2f")")
                .font(.system(size: 11, design: .monospaced))
            Slider(value: value, in: range)
                .frame(width: 150)
        }
    }

    private func zoomSlider(_ title: String,
                            value: Binding<Int>,
                            range: ClosedRange<Int>) -> some View {
        VStack(spacing: 2) {
            Text("\(title): \(value.wrappedValue)")
                .font(.system(size: 11, design: .monospaced))
            Slider(value: Binding(get: { Double(value.wrappedValue) },
                                  set: { value.wrappedValue = Int($0.rounded()) }),
                   in: Double(range.lowerBound)...Double(range.upperBound),
                   step: 1)
                .frame(width: 150)
        }
    }

    private static let paris = ImmersiveMapCameraPosition(
        latitudeDegrees: 48.8566,
        longitudeDegrees: 2.3522,
        zoom: 13.5,
        bearing: 0,
        pitch: 0.2
    )

    private static let tokyo = ImmersiveMapCameraPosition(
        latitudeDegrees: 35.6595,
        longitudeDegrees: 139.7005,
        zoom: 13.5,
        bearing: 0,
        pitch: 0.2
    )

    private static let overview = ImmersiveMapCameraPosition(
        latitudeDegrees: 30,
        longitudeDegrees: 20,
        zoom: 2.2,
        bearing: 0,
        pitch: 0.08
    )
}
