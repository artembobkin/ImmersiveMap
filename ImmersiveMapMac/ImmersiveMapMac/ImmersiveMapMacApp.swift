// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import SwiftUI
import ImmersiveMap

@main
struct ImmersiveMapMacApp: App {
    var body: some Scene {
        WindowGroup {
            MapScreen()
        }
    }
}

/// Demo scene: a globe with SwiftUI city cards and avatar markers plus a
/// looped cinematic tour (globe, tilted morph into the plane, Tokyo streets,
/// a flight to Dubai and back). The tour starts with the button or the R key,
/// and stops with R again, Esc, or any gesture on the map.
private struct MapScreen: View {
    @State private var camera = ImmersiveMapCameraController()
    @State private var avatarsController = ImmersiveMapAvatarsController()
    @State private var tour: ImmersiveMapCameraTourController?
    @State private var isTourRunning = false
    @State private var showChrome = true

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ImmersiveMapView()
                .camera(camera, position: CinematicStoryboard.overview)
                .buildingExtrusionMode(.solidAtHighZoom(startZoom: 16.5, endZoom: 17))
                .avatars(avatarsController)
                .markers(DemoMarkerPlaces.all, coordinate: { $0.coordinate }, anchor: .bottom) { place in
                    CityCardMarker(place: place)
                }
                .enableCameraUIControls(showChrome)
                .avatarSettings(size: .px128)
                // The cinematic tour loops the globe and two cities: an enlarged
                // memory cache of GPU-ready tiles (1 GiB instead of 256 MiB) so
                // tiles are not evicted and re-uploaded between laps.
                .tileSettings(memoryCacheSizeInBytes: 1_073_741_824)
                .ignoresSafeArea()

            if showChrome {
                controls
                    .padding(16)
            }

            // Hidden hotkeys: R starts and stops the tour, Esc stops it.
            hotkeys
        }
        .task {
            DemoAvatars.populate(avatarsController)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                toggleTour()
            } label: {
                Label(isTourRunning ? "Stop" : "Cinematic Tour",
                      systemImage: isTourRunning ? "stop.circle.fill" : "play.circle.fill")
            }
            .keyboardShortcut("r", modifiers: [])
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var hotkeys: some View {
        ZStack {
            Button("") { if isTourRunning { stopTour() } }
                .keyboardShortcut(.escape, modifiers: [])
            if showChrome == false {
                Button("") { stopTour() }
                    .keyboardShortcut("r", modifiers: [])
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    private func toggleTour() {
        if isTourRunning {
            stopTour()
        } else {
            startTour()
        }
    }

    private func startTour() {
        let tour = tour ?? ImmersiveMapCameraTourController(camera: camera)
        self.tour = tour
        isTourRunning = true
        // Hiding the controls does not recreate the platform map view (the
        // body identity is stable) and does not change the map settings, so
        // the tour can start immediately without waiting for a SwiftUI commit.
        showChrome = false
        tour.start(shots: CinematicStoryboard.makeShots(),
                   establish: CinematicStoryboard.overview,
                   loop: true) {
            isTourRunning = false
            showChrome = true
        }
    }

    private func stopTour() {
        tour?.stop()
    }
}
