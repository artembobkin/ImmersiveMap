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

/// Демо-сцена: глобус с SwiftUI-карточками городов и аватар-маркерами плюс
/// зацикленный кино-тур (глобус, наклонный морф в плоскость, улицы Токио,
/// перелёт в Дубай и обратно). Тур запускается кнопкой или клавишей R,
/// останавливается повторным R, Esc или любым жестом по карте.
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
                // Кино-тур гоняет глобус и два города по лупу: расширенный
                // memory-кэш GPU-ready тайлов (1 GiB вместо 256 MiB), чтобы
                // между витками тайлы не вытеснялись и не перезаливались.
                .tileSettings(memoryCacheSizeInBytes: 1_073_741_824)
                .ignoresSafeArea()

            if showChrome {
                controls
                    .padding(16)
            }

            // Скрытые горячие клавиши: R запускает и останавливает тур,
            // Esc останавливает.
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
        // Скрытие контролов не пересоздаёт платформенный map view (identity
        // body стабильна) и настройки карты не меняет, поэтому тур можно
        // запускать сразу, без ожидания коммита SwiftUI.
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
