// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImmersiveMap

@main
struct ImmersiveMapCameraTourMacApp: App {
    var body: some Scene {
        WindowGroup("ImmersiveMap Camera Tour") {
            TourScreen()
        }
        .defaultSize(width: 1100, height: 800)
    }
}

/// Scripted camera tour: a looped cinematic (globe, a tilted pass through the
/// globe-to-flat morph, Tokyo streets, a flight to Dubai and back) driven by
/// `ImmersiveMapCameraTourController`. The tour starts with the button or the R
/// key, and stops with R again, Esc, or any gesture on the map.
///
/// "Export Video" replays the same shot list offline through
/// `ImmersiveMapTourVideoRecorder` and writes a QuickTime file while the
/// on-screen map stays fully interactive.
private struct TourScreen: View {
    @State private var camera = ImmersiveMapCameraController()
    @State private var tour: ImmersiveMapCameraTourController?
    @State private var videoRecorder = ImmersiveMapTourVideoRecorder()
    @State private var isTourRunning = false
    @State private var isExportingVideo = false
    @State private var videoExportFraction: Double = 0
    @State private var showChrome = true

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ImmersiveMapView()
                .tileURLTemplate(hostedTileTemplate, headers: hostedTileHeaders())
                .camera(camera, position: CinematicStoryboard.overview)
                .enableCameraUIControls(showChrome)
                .tourVideoRecorder(videoRecorder)
                // The cinematic tour loops the globe and two cities. Tiles
                // leave GPU memory as soon as the camera has passed them, so
                // every lap returns through the prepared disk cache: the
                // quota is doubled so one lap never prunes the previous
                // lap's tiles.
                .preparedTileDiskCacheSize(bytes: 4 * 1_024 * 1_024 * 1_024)
                .ignoresSafeArea()

            if showChrome {
                controls
                    .padding(16)
            }

            // Hidden hotkeys: R starts and stops the tour, Esc stops it.
            hotkeys
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

/// The hosted tile endpoint, written as the one-line URL template. The API key
/// comes from `IMMERSIVEMAP_API_KEY` in the environment or from the gitignored
/// `LocalSecrets.plist` at the repository root, so a real key never has to be
/// typed into a committed scheme; without a key the map renders on the shared
/// anonymous pool.
private let hostedTileTemplate = "https://immersivemap.dev/tiles/{z}/{x}/{y}.mvt"

private func hostedTileHeaders() -> [String: String] {
    guard let key = localAPIKey(), key.isEmpty == false else {
        return [:]
    }
    return ["Authorization": "Bearer \(key)"]
}

/// The environment wins (the scheme carries an empty placeholder for it);
/// otherwise the key comes from the gitignored `LocalSecrets.plist` at the
/// repository root, found from this source file's path, which exists wherever
/// the app can also read it: on the Mac and in the simulator. A physical
/// device sees neither and uses the scheme variable.
private func localAPIKey() -> String? {
    if let key = ProcessInfo.processInfo.environment["IMMERSIVEMAP_API_KEY"],
       key.isEmpty == false {
        return key
    }
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while directory.path != "/" {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
            let secrets = directory.appendingPathComponent("LocalSecrets.plist")
            return NSDictionary(contentsOf: secrets)?["IMMERSIVEMAP_API_KEY"] as? String
        }
        directory = directory.deletingLastPathComponent()
    }
    return nil
}
