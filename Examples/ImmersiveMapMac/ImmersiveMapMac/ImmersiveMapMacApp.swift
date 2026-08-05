// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import UniformTypeIdentifiers
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
/// and stops with R again, Esc, or any gesture on the map. "Export Video"
/// renders one lap of the same tour offline into a QuickTime file while the
/// on-screen map stays interactive.
private struct MapScreen: View {
    @State private var camera = ImmersiveMapCameraController()
    @State private var avatarsController = ImmersiveMapAvatarsController()
    @State private var sceneModelsController = ImmersiveMapSceneModelsController()
    @State private var tour: ImmersiveMapCameraTourController?
    @State private var videoRecorder = ImmersiveMapTourVideoRecorder()
    @State private var isTourRunning = false
    @State private var isExportingVideo = false
    @State private var videoExportFraction: Double = 0
    @State private var showChrome = true

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ImmersiveMapView()
                .camera(camera, position: CinematicStoryboard.overview)
                .buildingExtrusionMode(.solidAtHighZoom(startZoom: 16.5, endZoom: 17))
                .avatars(avatarsController)
                .sceneModels(sceneModelsController)
                .markers(DemoMarkerPlaces.all, coordinate: { $0.coordinate }, anchor: .bottom) { place in
                    CityCardMarker(place: place)
                }
                .enableCameraUIControls(showChrome)
                .avatarSettings(size: .px128)
                .tourVideoRecorder(videoRecorder)
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
            DemoSceneModels.populate(sceneModelsController)
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

            if isExportingVideo {
                ProgressView(value: videoExportFraction)
                    .frame(width: 120)
                Button {
                    videoRecorder.cancel()
                } label: {
                    Label("Cancel Export", systemImage: "xmark.circle.fill")
                }
            } else {
                Button {
                    exportTourVideo()
                } label: {
                    Label("Export Video", systemImage: "film.circle.fill")
                }
            }
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

    /// Renders one lap of the storyboard offline (1080p60 HEVC by default)
    /// while the on-screen map stays fully interactive.
    private func exportTourVideo() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = "ImmersiveMapTour.mov"
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        isExportingVideo = true
        videoExportFraction = 0
        videoRecorder.onProgress = { progress in
            videoExportFraction = progress.fractionCompleted
        }
        Task {
            defer {
                isExportingVideo = false
            }
            do {
                try await videoRecorder.export(shots: CinematicStoryboard.makeShots(),
                                               establish: CinematicStoryboard.overview,
                                               to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                print("Tour video export failed: \(error)")
                NSSound.beep()
            }
        }
    }
}

/// Demo 3D scene models: a real textured USDZ from the app bundle plus a
/// runtime-written OBJ obelisk (two sources demonstrate mesh sharing and mixed
/// formats). The USDZ is "Spot" by Keenan Crane, released into the public
/// domain (https://www.cs.cmu.edu/~kmcrane/Projects/ModelRepository/),
/// repackaged from OBJ into USDZ with the texture embedded.
private enum DemoSceneModels {
    static func populate(_ controller: ImmersiveMapSceneModelsController) {
        var models: [ImmersiveMapSceneModel] = []
        if let spot = ImmersiveMapSceneModel.Source(resource: "spot", withExtension: "usdz") {
            // A landmark-sized cow by the Eiffel Tower.
            models.append(ImmersiveMapSceneModel(id: 9001,
                                                 source: spot,
                                                 coordinate: GeoCoordinate(latitude: 48.8570, longitude: 2.2952),
                                                 headingDegrees: -35,
                                                 fitDiameterMeters: 160))
            // Her sister flying over Paris: exercises altitude and pitch.
            models.append(ImmersiveMapSceneModel(id: 9002,
                                                 source: spot,
                                                 coordinate: GeoCoordinate(latitude: 48.8615, longitude: 2.2890),
                                                 altitudeMeters: 260,
                                                 headingDegrees: 120,
                                                 pitchDegrees: 12,
                                                 fitDiameterMeters: 110))
            // Tokyo (the cinematic tour passes it by).
            models.append(ImmersiveMapSceneModel(id: 9003,
                                                 source: spot,
                                                 coordinate: GeoCoordinate(latitude: 35.6595, longitude: 139.7005),
                                                 headingDegrees: 30,
                                                 fitDiameterMeters: 220))
        }
        if let obeliskURL = writeObeliskOBJ() {
            // Dubai spire next to the Burj Khalifa.
            models.append(ImmersiveMapSceneModel(id: 9004,
                                                 source: ImmersiveMapSceneModel.Source(url: obeliskURL),
                                                 coordinate: GeoCoordinate(latitude: 25.1972, longitude: 55.2744),
                                                 fitDiameterMeters: 500))
        }
        controller.set(models)
    }

    /// A tapered obelisk with a pyramid top: Y-up, base at y = 0 so the model
    /// stands on the map surface, 1 unit tall (sized via `fitDiameterMeters`).
    private static func writeObeliskOBJ() -> URL? {
        let obj = """
        v -0.08 0 -0.08
        v 0.08 0 -0.08
        v 0.08 0 0.08
        v -0.08 0 0.08
        v -0.06 0.75 -0.06
        v 0.06 0.75 -0.06
        v 0.06 0.75 0.06
        v -0.06 0.75 0.06
        v 0 1 0
        f 1 5 6
        f 1 6 2
        f 2 6 7
        f 2 7 3
        f 3 7 8
        f 3 8 4
        f 4 8 5
        f 4 5 1
        f 5 9 6
        f 6 9 7
        f 7 9 8
        f 8 9 5
        f 1 2 3
        f 1 3 4
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("immersive-map-demo-obelisk.obj")
        do {
            try obj.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
